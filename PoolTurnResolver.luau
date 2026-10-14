-- PoolTurnResolver
--
-- Decides what a finished shot means: fouls, group assignment, whether the
-- shooter continues, and how the frame ends.
--
-- The module is transport free. It never touches a RemoteEvent, a Part or the
-- Workspace: it mutates the game state it is given and returns an outcome that
-- the caller is free to broadcast however it likes. Sounds are collected into
-- the outcome rather than fired.

local PoolTurnResolver = {}
PoolTurnResolver.__index = PoolTurnResolver

-- Probe spacing when hunting for a free spot, in ball diameters.
local RESPOT_PROBE_FACTOR = 0.5

-- `world` is a PoolPhysics world; `tableConfig` supplies the foot spot and the
-- cushions that bound a legal re-spot.
function PoolTurnResolver.new(world, tableConfig)
	local self = setmetatable({}, PoolTurnResolver)
	self.world = world
	self.tableConfig = tableConfig or (PoolTurnResolver :: any).PoolTableConfig
	return self
end

local function newOutcome()
	return {
		Foul = false,
		ShootAgain = false,
		GameOver = false,
		Winner = nil,
		CueBallReplaced = false,
		Sounds = {},
		-- Balls the rules moved after the shot settled. The clients animate the
		-- recorded trajectory, so anything repositioned afterwards has to travel
		-- with the outcome or the screen keeps showing the ball in its pocket.
		Respots = {},
	}
end

local function addSound(outcome, name: string, volume: number?)
	table.insert(outcome.Sounds, { Name = name, Volume = volume or 1 })
end

local function describePlayer(State, playerIndex: number): string
	local player = if playerIndex == 1 then State.player1 else State.player2
	return player and player.Name or ("Player " .. playerIndex)
end

local function opponentOf(playerIndex: number): number
	return if playerIndex == 1 then 2 else 1
end

function PoolTurnResolver:_countPocketed(State)
	local pSolids, pStripes, eightPocketed = 0, 0, false
	for _, bid in ipairs(State.turnPocketed) do
		local g = State:getBallGroup(bid)
		if g == "solids" then pSolids += 1 end
		if g == "stripes" then pStripes += 1 end
		if g == "8ball" then eightPocketed = true end
	end
	return pSolids, pStripes, eightPocketed
end

-- How many balls of a group the shooter still owed BEFORE this shot. Balls
-- potted during the shot count as still owed, which is what makes "you must
-- clear your group before the 8" work even when both fall on the same stroke.
--
-- Single source of truth: the foul check and the win check both read it, so
-- they can never disagree about whether the shooter was on the 8-ball.
function PoolTurnResolver:_countGroupBallsBeforeShot(State, group: string?): number
	if not group then return 0 end

	local pottedThisTurn = {}
	for _, ballId in State.turnPocketed do
		pottedThisTurn[ballId] = true
	end

	local remaining = 0
	for _, ballId in self.world.BallOrder do
		local ball = self.world:GetBall(ballId)
		if ball and State:getBallGroup(ballId) == group then
			if not ball.IsPocketed or pottedThisTurn[ballId] then
				remaining += 1
			end
		end
	end

	return remaining
end

-- The shooter may legally play the 8-ball only with the group already cleared
-- before the stroke.
function PoolTurnResolver:_isOnTheEightBall(State): boolean
	if not State.assigned then return false end

	local group = State:currentPlayerType()
	if not group then return false end

	return self:_countGroupBallsBeforeShot(State, group) == 0
end

function PoolTurnResolver:_checkFoul(State, cuePocketed, wasBreak, pSolids, pStripes)
	-- Pocketing the cue ball is a foul on every stroke, the break included.
	if cuePocketed then return true end

	local nothingHappened = pSolids == 0 and pStripes == 0 and not State.railHitAfterContact

	if wasBreak then
		return nothingHappened
	end

	-- Table still open: any ball may be struck first.
	if not State.assigned then
		return nothingHappened
	end

	local group = State:currentPlayerType()
	local needToHit = if self:_countGroupBallsBeforeShot(State, group) > 0 then group else "8ball"

	if State.firstHitGroup == nil then return true end
	if State.firstHitGroup ~= needToHit then return true end

	return nothingHappened
end

function PoolTurnResolver:_checkWin(State, isFoul: boolean): boolean
	if isFoul then return false end
	return self:_isOnTheEightBall(State)
end

function PoolTurnResolver:_assignTypes(State, pSolids, pStripes)
	if State.assigned then return end
	if pSolids > 0 and pStripes == 0 then
		State.p1Type = if State.currentPlayer == 1 then "solids" else "stripes"
		State.p2Type = if State.p1Type == "solids" then "stripes" else "solids"
		State.assigned = true
	elseif pStripes > 0 and pSolids == 0 then
		State.p1Type = if State.currentPlayer == 1 then "stripes" else "solids"
		State.p2Type = if State.p1Type == "stripes" then "solids" else "stripes"
		State.assigned = true
	end
end

function PoolTurnResolver:_shootAgain(State, wasBreak, isFoul, pSolids, pStripes)
	if isFoul then return false end
	if wasBreak then return pSolids > 0 or pStripes > 0 end
	if State.assigned then
		local myType = State:currentPlayerType()
		for _, bid in ipairs(State.turnPocketed) do
			if State:getBallGroup(bid) == myType then return true end
		end
		return false
	end
	return (pSolids > 0 and pStripes == 0) or (pStripes > 0 and pSolids == 0)
end

-- A spot is legal when it sits inside the cushions and touches nobody.
function PoolTurnResolver:_isSpotFree(position: Vector2, ignoreBallId: string): boolean
	local radius = self.tableConfig.Ball.Radius
	local surface = self.tableConfig.Surface

	if math.abs(position.X) > surface.HalfLength - radius then return false end
	if math.abs(position.Y) > surface.HalfWidth - radius then return false end

	for _, ballId in self.world.BallOrder do
		if ballId == ignoreBallId then continue end
		local ball = self.world:GetBall(ballId)
		if ball and not ball.IsPocketed and (ball.Position - position).Magnitude < radius * 2 then
			return false
		end
	end

	return true
end

-- The foot spot first, then outwards along the long string -- the axis a real
-- table spots on -- taking whichever side comes up free first.
function PoolTurnResolver:_findRespotPosition(ignoreBallId: string): Vector2
	local surface = self.tableConfig.Surface
	local footSpot = Vector2.new(surface.FootSpotX, 0)
	if self:_isSpotFree(footSpot, ignoreBallId) then
		return footSpot
	end

	local probeStep = self.tableConfig.Ball.Diameter * RESPOT_PROBE_FACTOR
	local maximumOffset = surface.HalfLength * 2
	local offset = probeStep

	while offset <= maximumOffset do
		for _, direction in { 1, -1 } do
			local candidate = Vector2.new(surface.FootSpotX + direction * offset, 0)
			if self:_isSpotFree(candidate, ignoreBallId) then
				return candidate
			end
		end
		offset += probeStep
	end

	return footSpot
end

function PoolTurnResolver:_respotBall(outcome, ballId: string, position: Vector2)
	local ball = self.world:GetBall(ballId)
	if not ball then return end

	ball.IsPocketed = false
	ball.Position = position
	ball.Velocity = Vector2.zero
	ball.AngularVelocity = 0

	table.insert(outcome.Respots, { Id = ballId, X = position.X, Y = position.Y })
end

-- Potting the 8-ball on the break costs nothing: it goes back on the table and
-- the frame carries on. A scratch on the same stroke is still a foul.
function PoolTurnResolver:_respotEightBallAfterBreak(State, outcome)
	self:_respotBall(outcome, "ball_8", self:_findRespotPosition("ball_8"))

	for index, ballId in State.turnPocketed do
		if ballId == "ball_8" then
			table.remove(State.turnPocketed, index)
			break
		end
	end
end

function PoolTurnResolver:_applyFoul(State, outcome, cueBall, cuePocketed, cueBallStartX)
	State.currentPlayer = opponentOf(State.currentPlayer)

	if cuePocketed and cueBall then
		self:_respotBall(outcome, "cue", Vector2.new(cueBallStartX, 0))
		outcome.CueBallReplaced = true
	end

	State.phase = "BALL_IN_HAND"
	State.message = "Foul! " .. describePlayer(State, State.currentPlayer) .. " — Ball in Hand."
end

local function describeLoss(wasBreak: boolean, isFoul: boolean, cuePocketed: boolean): string
	if cuePocketed then return "scratched on the 8-ball" end
	if isFoul then return "fouled on the 8-ball" end
	return "8-ball potted too early"
end

-- The 8-ball ends the frame however it falls: legally it wins, in every other
-- case the opponent takes it. This runs on the break too, so the break can no
-- longer swallow the 8-ball and carry on without it.
function PoolTurnResolver:_resolveEightBall(State, outcome, isFoul, wasBreak, cuePocketed)
	local didWin = self:_checkWin(State, isFoul)
	local shooterIndex = State.currentPlayer
	local shooterName = describePlayer(State, shooterIndex)
	local opponentIndex = opponentOf(shooterIndex)

	State.message = didWin
		and (shooterName .. " WINS!")
		or string.format("%s WINS! (%s: %s)",
			describePlayer(State, opponentIndex), shooterName, describeLoss(wasBreak, isFoul, cuePocketed))

	if isFoul then
		addSound(outcome, "foul")
	end

	State.phase = "GAME_OVER"
	outcome.Foul = isFoul
	outcome.GameOver = true
	outcome.Winner = didWin and shooterIndex or opponentIndex
	return outcome
end

function PoolTurnResolver:_continueSameShooter(State, wasBreak)
	State.phase = "AIMING"
	local label = wasBreak and "Break! " or ""
	State.message = label .. describePlayer(State, State.currentPlayer) .. " shoots again!"
end

function PoolTurnResolver:_passTurn(State)
	State.currentPlayer = opponentOf(State.currentPlayer)
	State.phase = "AIMING"
	State.message = describePlayer(State, State.currentPlayer) .. "'s turn."
end

local function clearShotTracking(State)
	State.railHitAfterContact = false
	State.cueFirstContactDone = false
	State.firstHitGroup = nil
end

-- Reads the settled world, mutates `State`, and returns what happened.
-- The caller decides how to tell anyone about it.
function PoolTurnResolver:resolve(State, cueBallStartX: number)
	local outcome = newOutcome()
	local cueBall = self.world:GetBall("cue")
	local cuePocketed = cueBall ~= nil and cueBall.IsPocketed
	local wasBreak = State.isBreakShot
	State.isBreakShot = false

	local pSolids, pStripes, eightPocketed = self:_countPocketed(State)
	local isFoul = self:_checkFoul(State, cuePocketed, wasBreak, pSolids, pStripes)

	if eightPocketed and wasBreak then
		-- Handled and then forgotten: the break resolves as if the 8-ball had
		-- never dropped.
		self:_respotEightBallAfterBreak(State, outcome)
	elseif eightPocketed then
		return self:_resolveEightBall(State, outcome, isFoul, wasBreak, cuePocketed)
	end

	if not isFoul and not wasBreak then
		self:_assignTypes(State, pSolids, pStripes)
	end

	if isFoul then
		addSound(outcome, "foul")
	end

	local shootAgain = self:_shootAgain(State, wasBreak, isFoul, pSolids, pStripes)
	clearShotTracking(State)

	outcome.Foul = isFoul
	outcome.ShootAgain = shootAgain and not isFoul

	if isFoul then
		self:_applyFoul(State, outcome, cueBall, cuePocketed, cueBallStartX)
		return outcome
	end

	if shootAgain then
		self:_continueSameShooter(State, wasBreak)
		return outcome
	end

	self:_passTurn(State)
	return outcome
end

return PoolTurnResolver