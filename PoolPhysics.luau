local PoolPhysics = {}
PoolPhysics.__index = PoolPhysics

local function clamp(v, lo, hi)
	return v < lo and lo or v > hi and hi or v
end

local function safeUnit(v)
	local m = v.Magnitude
	return m <= 1e-9 and Vector2.zero or v / m
end

local function perp(v)
	return Vector2.new(-v.Y, v.X)
end

local function defaultConfig()
	return {
		-- Fallback only. The authority is PoolTableConfig.Physics, which
		-- PoolMatch merges over these on every world it builds; these mirror
		-- the frozen set so a world created without a config cannot silently
		-- run on a different simulation than the game does.
		RollingFriction           = 0.12,
		SlidingFriction           = 0.26,
		BallRestitution           = 0.95,
		RailRestitution           = 0.78,
		RailFriction              = 0.97,
		SpinDamping               = 3.0,
		LinearStopThreshold       = 0.02,
		AngularStopThreshold      = 0.03,
		MaxSubsteps               = 8,
		Gravity                   = 9.81,
		PositionCorrectionPercent = 0.85,
		PositionCorrectionSlop    = 0.0003,
	}
end

function PoolPhysics.newWorld(config)
	local merged = defaultConfig()
	if config then
		for k, v in config do merged[k] = v end
	end
	return setmetatable({
		Config    = merged,
		Balls     = {},
		BallOrder = {},
		Cushions  = {},
		Pockets   = {},
	}, PoolPhysics)
end

function PoolPhysics:AddBall(data)
	local ball = {
		Id              = data.Id,
		Position        = data.Position,
		Velocity        = data.Velocity or Vector2.zero,
		AngularVelocity = data.AngularVelocity or 0,
		Radius          = data.Radius,
		Mass            = data.Mass,
		LinearDamping   = data.LinearDamping,
		SpinDamping     = data.SpinDamping,
		IsPocketed      = false,
		UserData        = data.UserData,
	}
	self.Balls[ball.Id] = ball
	table.insert(self.BallOrder, ball.Id)
	return ball
end

function PoolPhysics:AddCushion(data)
	local normal  = safeUnit(data.Normal)
	local tangent = data.Tangent and safeUnit(data.Tangent) or perp(normal)
	local cushion = {
		Point           = data.Point,
		Normal          = normal,
		Length          = data.Length,
		Tangent         = tangent,
		Center          = data.Center,
		RailRestitution = data.RailRestitution,
		RailFriction    = data.RailFriction,
		SpinInfluence   = data.SpinInfluence,
	}
	table.insert(self.Cushions, cushion)
	return cushion
end

function PoolPhysics:AddPocket(data)
	local pocket = {
		Center       = data.Center,
		Radius       = data.Radius,
		CaptureDepth = data.CaptureDepth,
	}
	table.insert(self.Pockets, pocket)
	return pocket
end

function PoolPhysics:GetBall(ballId)
	return self.Balls[ballId]
end

function PoolPhysics:RemoveBall(ballId)
	self.Balls[ballId] = nil
	for i, id in self.BallOrder do
		if id == ballId then table.remove(self.BallOrder, i); break end
	end
end

function PoolPhysics:ApplyCueStrike(ballId, direction, impulse, offset)
	local ball = self.Balls[ballId]
	if not ball or ball.IsPocketed then return end
	local dir = safeUnit(direction)
	if dir == Vector2.zero then return end
	ball.Velocity += dir * (impulse / ball.Mass)
	if offset and math.abs(offset) > 0 then
		local inertia = (2/5) * ball.Mass * ball.Radius * ball.Radius
		ball.AngularVelocity += (impulse * offset) / inertia
	end
end

function PoolPhysics:IsAnythingMoving()
	for _, id in self.BallOrder do
		local b = self.Balls[id]
		if b and not b.IsPocketed then
			if b.Velocity.Magnitude > self.Config.LinearStopThreshold
				or math.abs(b.AngularVelocity) > self.Config.AngularStopThreshold
			then
				return true
			end
		end
	end
	return false
end

function PoolPhysics:Step(dt)
	local collisions = {}
	local pocketed   = {}
	if dt <= 0 then
		return { Collisions = collisions, Pocketed = pocketed, Moving = self:IsAnythingMoving() }
	end
	local substeps = clamp(math.ceil(dt / (1/180)), 1, self.Config.MaxSubsteps)
	local stepDt   = dt / substeps
	for _ = 1, substeps do
		self:_integrate(stepDt)
		self:_resolveBallBall(collisions)
		self:_resolveRails(collisions)
		self:_resolvePockets(collisions, pocketed)
		self:_applySleep()
	end
	return { Collisions = collisions, Pocketed = pocketed, Moving = self:IsAnythingMoving() }
end

function PoolPhysics:_integrate(dt)
	local g = self.Config.Gravity
	for _, id in self.BallOrder do
		local ball = self.Balls[id]
		if not ball or ball.IsPocketed then continue end

		local speed = ball.Velocity.Magnitude
		if speed < 1e-9 and math.abs(ball.AngularVelocity) < 1e-9 then continue end

		if speed > 1e-9 then
			local dir  = ball.Velocity / speed
			local rimSpd = math.abs(ball.AngularVelocity) * ball.Radius
			local slip = math.abs(speed - rimSpd)

			local mu
			if slip > 0.12 then
				mu = self.Config.SlidingFriction
			elseif slip > 0.005 then
				local t = (slip - 0.005) / (0.12 - 0.005)
				mu = self.Config.RollingFriction + t * (self.Config.SlidingFriction - self.Config.RollingFriction)
			else
				mu = self.Config.RollingFriction
			end

			local decel    = mu * g
			local newSpeed = math.max(0, speed - decel * dt)

			if ball.LinearDamping and ball.LinearDamping > 0 then
				newSpeed = newSpeed * math.exp(-ball.LinearDamping * dt)
			end

			ball.Velocity = dir * newSpeed
			ball.Position = ball.Position + ball.Velocity * dt

			if newSpeed > 1e-6 then
				local targetOmega = newSpeed / math.max(ball.Radius, 1e-9)
				local spinDiff    = targetOmega - math.abs(ball.AngularVelocity)
				local delta       = spinDiff * math.min(1, 14 * dt)
				ball.AngularVelocity += if ball.AngularVelocity >= 0 then delta else -delta
			end
		end

		local sd = ball.SpinDamping or self.Config.SpinDamping
		if sd > 0 then
			ball.AngularVelocity *= math.exp(-sd * dt)
		end
	end
end

function PoolPhysics:_resolveBallBall(collisions)
	local ids  = self.BallOrder
	local e    = self.Config.BallRestitution
	local pct  = self.Config.PositionCorrectionPercent
	local slop = self.Config.PositionCorrectionSlop

	for i = 1, #ids - 1 do
		local bA = self.Balls[ids[i]]
		if not bA or bA.IsPocketed then continue end
		for j = i + 1, #ids do
			local bB = self.Balls[ids[j]]
			if not bB or bB.IsPocketed then continue end

			local delta = bB.Position - bA.Position
			local dist  = delta.Magnitude
			local minD  = bA.Radius + bB.Radius

			if dist <= 1e-9 then delta = Vector2.new(minD, 0); dist = minD end
			if dist > minD then continue end

			local normal = delta / dist
			local pen    = minD - dist

			if pen > slop then
				local totalInvMass = (1/bA.Mass) + (1/bB.Mass)
				local corrMag      = ((pen - slop) / totalInvMass) * pct
				bA.Position -= normal * (corrMag / bA.Mass)
				bB.Position += normal * (corrMag / bB.Mass)
			end

			local relVel = bB.Velocity - bA.Velocity
			local vn     = relVel:Dot(normal)
			if vn > 0 then continue end

			local totalInvMass = (1/bA.Mass) + (1/bB.Mass)
			local impScalar    = (-(1 + e) * vn) / totalInvMass
			local imp          = normal * impScalar
			bA.Velocity -= imp / bA.Mass
			bB.Velocity += imp / bB.Mass

			local tangent    = perp(normal)
			local relTan     = relVel:Dot(tangent)
			local frictionCap = math.abs(impScalar) * 0.05
			local frictionImp = clamp(-relTan / totalInvMass, -frictionCap, frictionCap)
			local fImpVec     = tangent * frictionImp
			bA.Velocity -= fImpVec / bA.Mass
			bB.Velocity += fImpVec / bB.Mass

			local inertiaA = (2/5) * bA.Mass * bA.Radius * bA.Radius
			local inertiaB = (2/5) * bB.Mass * bB.Radius * bB.Radius
			bA.AngularVelocity += (frictionImp * bA.Radius) / inertiaA
			bB.AngularVelocity -= (frictionImp * bB.Radius) / inertiaB

			table.insert(collisions, {
				Type     = "BallBall",
				BallA    = bA.Id,
				BallB    = bB.Id,
				Position = bA.Position + normal * bA.Radius,
				Normal   = normal,
			})
		end
	end
end

function PoolPhysics:_resolveRails(collisions)
	for _, id in self.BallOrder do
		local ball = self.Balls[id]
		if not ball or ball.IsPocketed then continue end

		local nearPocket = false
		for _, pocket in self.Pockets do
			if (pocket.Center - ball.Position).Magnitude <= pocket.Radius * 1.1 then
				nearPocket = true
				break
			end
		end
		if nearPocket then continue end

		for _, cushion in self.Cushions do
			local normal  = cushion.Normal
			local tangent = cushion.Tangent or perp(normal)

			if cushion.Length and cushion.Center then
				local rel   = ball.Position - cushion.Center
				local along = rel:Dot(tangent)
				if math.abs(along) > cushion.Length * 0.5 + ball.Radius then continue end
			end

			local toBall     = ball.Position - cushion.Point
			local signedDist = toBall:Dot(normal)
			if signedDist >= ball.Radius then continue end

			ball.Position += normal * (ball.Radius - signedDist)

			local v        = ball.Velocity
			local vnScalar = v:Dot(normal)
			if vnScalar >= 0 then continue end

			local vn   = normal * vnScalar
			local vt   = v - vn

			local railE      = cushion.RailRestitution or self.Config.RailRestitution
			local railF      = cushion.RailFriction    or self.Config.RailFriction
			local spinI      = cushion.SpinInfluence   or 0.04
			local spinContrib = tangent * (ball.AngularVelocity * ball.Radius * spinI)

			ball.Velocity        = (-railE * vn) + (vt * railF) + spinContrib
			ball.AngularVelocity *= 0.78

			table.insert(collisions, {
				Type     = "BallRail",
				BallA    = ball.Id,
				BallB    = nil,
				Position = ball.Position - normal * ball.Radius,
				Normal   = normal,
			})
		end
	end
end

function PoolPhysics:_resolvePockets(collisions, pocketed)
	for _, id in self.BallOrder do
		local ball = self.Balls[id]
		if not ball or ball.IsPocketed then continue end
		for _, pocket in self.Pockets do
			local dist     = (pocket.Center - ball.Position).Magnitude
			local captureR = pocket.CaptureDepth or (pocket.Radius - ball.Radius * 0.3)
			if dist <= captureR then
				ball.IsPocketed      = true
				ball.Velocity        = Vector2.zero
				ball.AngularVelocity = 0
				ball.Position        = pocket.Center
				table.insert(pocketed, ball.Id)
				table.insert(collisions, {
					Type     = "Pocket",
					BallA    = ball.Id,
					BallB    = nil,
					Position = pocket.Center,
					Normal   = nil,
				})
				break
			end
		end
	end
end

function PoolPhysics:_applySleep()
	for _, id in self.BallOrder do
		local ball = self.Balls[id]
		if not ball or ball.IsPocketed then continue end
		if ball.Velocity.Magnitude < self.Config.LinearStopThreshold then
			ball.Velocity = Vector2.zero
		end
		if math.abs(ball.AngularVelocity) < self.Config.AngularStopThreshold then
			ball.AngularVelocity = 0
		end
	end
end

function PoolPhysics:ResetMotion()
	for _, id in self.BallOrder do
		local ball = self.Balls[id]
		if ball then
			ball.Velocity        = Vector2.zero
			ball.AngularVelocity = 0
		end
	end
end

function PoolPhysics:GetActiveBalls()
	local result = {}
	for _, id in self.BallOrder do
		local ball = self.Balls[id]
		if ball and not ball.IsPocketed then
			table.insert(result, ball)
		end
	end
	return result
end

return PoolPhysics