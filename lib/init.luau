local RunService = game:GetService("RunService")

local isClient = RunService:IsClient()
local isServer = RunService:IsServer()

local CentralServer : typeof(require(script.CentralServer))
if isServer then
    CentralServer = require(script.CentralServer)
end

local CentralClient : typeof(require(script.CentralClient))
if isClient then
    CentralClient = require(script.CentralClient)
end

local bolt = require(script.bolt)
local visualizer = require(script.visualizer)
local Settings = require(script.Settings)

local RAYCAST_MARGIN = 1e-4

local DEBUG_MODE = Settings.DEBUG_MODE
local DEBUG_LIFETIME = Settings.DEBUG_LIFETIME
local DEBUG_RAY_COLOR = Color3.new(0, 0, 1)
local DEBUG_HIT_COLOR = Color3.new(0, 1, 0)

export type QueryConfiguration = {
    frameRange:number?,
    check:((part:BasePart)->(boolean))?
}


local Central =  {Settings = Settings}

local hasStarted = false

function Central.Start()
    if hasStarted then
        warn("Central.Start can only be called once")
        return
    end
    hasStarted = true

    if isServer then
        CentralServer.Start()
    end

    if isClient then
        task.spawn(function()
            CentralClient.Start()
        end)
    end
end

function Central.AddCollisionGroup(name: string)
    if not isServer then
        warn("Central.AddCollisionGroup can only be called on the server")
        return
    end
    CentralServer.AddCollisionGroup(name)
end

function Central.RemoveCollisionGroup(name: string)
    if not isServer then
        warn("Central.RemoveCollisionGroup can only be called on the server")
        return
    end
    CentralServer.RemoveCollisionGroup(name)
end

function Central.AddQueryGroup(name: string)
    if not isServer then
        warn("Central.AddQueryGroup can only be called on the server")
        return
    end
    CentralServer.AddQueryGroup(name)
end

function Central.RemoveQueryGroup(name: string)
    if not isServer then
        warn("Central.RemoveQueryGroup can only be called on the server")
        return
    end
    CentralServer.RemoveQueryGroup(name)
end

local debugDraws: {{draw: () -> (), expireTime: number}} = {}

local function pushDebugDraw(draw: () -> ())
    table.insert(debugDraws, {draw = draw, expireTime = os.clock() + DEBUG_LIFETIME})
end

if DEBUG_MODE then
    RunService.PostSimulation:Connect(function()
        local now = os.clock()
        for i = #debugDraws, 1, -1 do
            local entry = debugDraws[i]
            if now > entry.expireTime then
                table.remove(debugDraws, i)
                continue
            end
            entry.draw()
        end
    end)
end

local function filterByInclude(owned: {BasePart}, include: {Instance}?): {BasePart}
    if not include or #include == 0 then
        return owned
    end

    local filtered = {}
    for _, part in owned do
        for _, included in include do
            if part == included or part:IsDescendantOf(included) then
                table.insert(filtered, part)
                break
            end
        end
    end
    return filtered
end

local function raycastExcludeRetry(origin: Vector3, direction: Vector3, params: RaycastParams, check: (BasePart) -> boolean): (RaycastResult?, number?)
    local unit = direction.Unit
    local remainingLength = direction.Magnitude
    local currentOrigin = origin
    local traveledTotal = 0

    local exclude: {Instance} = if params.ExcludeInstances then table.clone(params.ExcludeInstances) else {}

    while remainingLength > RAYCAST_MARGIN do
        params.ExcludeInstances = exclude
        local result = workspace:Raycast(currentOrigin, unit * remainingLength, params)
        if not result then
            return nil, nil
        end
        if check(result.Instance) then
            return result, traveledTotal + result.Distance
        end

        table.insert(exclude, result.Instance)

        local step = result.Distance + RAYCAST_MARGIN
        currentOrigin += unit * step
        remainingLength -= step
        traveledTotal += step
    end

    return nil, nil
end

local function shapecastExcludeRetry(part: Part, direction: Vector3, params: RaycastParams, check: (BasePart) -> boolean): RaycastResult?
    local exclude: {Instance} = if params.ExcludeInstances then table.clone(params.ExcludeInstances) else {}

    while true do
        params.ExcludeInstances = exclude
        local result = workspace:Shapecast(part, direction, params)
        if not result then
            return nil
        end
        if check(result.Instance) then
            return result
        end

        table.insert(exclude, result.Instance)
    end
end

local function liveHitboxAwareRaycast(player: Player, origin: Vector3, direction: Vector3, params: RaycastParams?, check: ((BasePart) -> boolean)?): (RaycastResult?, number?)
    local blanket = RaycastParams.new()
    if params then
        if params.ExcludeInstances then
            blanket.ExcludeInstances = params.ExcludeInstances
        end
        if params.IncludeInstances then
            blanket.IncludeInstances = params.IncludeInstances
        end
        if params.RespectCanCollide ~= nil then
            blanket.RespectCanCollide = params.RespectCanCollide
        end
    end
    if params and params.CollisionGroup and CentralServer.IsQueryGroup(params.CollisionGroup) then
        blanket.CollisionGroup = params.CollisionGroup
    else
        blanket.CollisionGroup = Settings.DEFAULT_HITBOX_QUERY_GROUP
    end

    local result: RaycastResult?
    local resultDistance: number?
    if check then
        result, resultDistance = raycastExcludeRetry(origin, direction, blanket, check)
    else
        result = workspace:Raycast(origin, direction, blanket)
    end

    local owned = CentralServer.GetOwnedHitboxParts(player)
    if #owned > 0 then
        local ownedParams = RaycastParams.new()
        if params then
            if params.ExcludeInstances then
                ownedParams.ExcludeInstances = params.ExcludeInstances
            end
            if params.CollisionGroup then
                ownedParams.CollisionGroup = params.CollisionGroup
            end
            if params.RespectCanCollide ~= nil then
                ownedParams.RespectCanCollide = params.RespectCanCollide
            end
        end
        ownedParams.IncludeInstances = filterByInclude(owned, if params then params.IncludeInstances else nil)

        if check then
            local ownedResult, ownedDistance = raycastExcludeRetry(origin, direction, ownedParams, check)
            if ownedResult and (not result or (ownedDistance :: number) < (resultDistance :: number)) then
                result = ownedResult
                resultDistance = ownedDistance
            end
        else
            local ownedResult = workspace:Raycast(origin, direction, ownedParams)
            if ownedResult and (not result or ownedResult.Distance < result.Distance) then
                result = ownedResult
            end
        end
    end

    return result, resultDistance
end

local function liveHitboxAwareOverlap(player: Player, queryFn: (OverlapParams?) -> {BasePart}, params: OverlapParams?, check: ((BasePart) -> boolean)?): {BasePart}
    local blanket = OverlapParams.new()
    if params then
        if params.ExcludeInstances then
            blanket.ExcludeInstances = params.ExcludeInstances
        end
        if params.IncludeInstances then
            blanket.IncludeInstances = params.IncludeInstances
        end
        if params.RespectCanCollide ~= nil then
            blanket.RespectCanCollide = params.RespectCanCollide
        end
        if params.MaxParts then
            blanket.MaxParts = params.MaxParts
        end
    end
    if params and params.CollisionGroup and CentralServer.IsQueryGroup(params.CollisionGroup) then
        blanket.CollisionGroup = params.CollisionGroup
    else
        blanket.CollisionGroup = Settings.DEFAULT_HITBOX_QUERY_GROUP
    end
    local result = queryFn(blanket)

    local owned = CentralServer.GetOwnedHitboxParts(player)
    if #owned > 0 then
        local ownedParams = OverlapParams.new()
        if params then
            if params.ExcludeInstances then
                ownedParams.ExcludeInstances = params.ExcludeInstances
            end
            if params.CollisionGroup then
                ownedParams.CollisionGroup = params.CollisionGroup
            end
            if params.RespectCanCollide ~= nil then
                ownedParams.RespectCanCollide = params.RespectCanCollide
            end
            if params.MaxParts then
                ownedParams.MaxParts = params.MaxParts
            end
        end
        ownedParams.IncludeInstances = filterByInclude(owned, if params then params.IncludeInstances else nil)
        local ownedResult = queryFn(ownedParams)
        for _, part in ownedResult do
            if not table.find(result, part) then
                table.insert(result, part)
            end
        end
    end

    if check then
        for i = #result, 1, -1 do
            if not check(result[i]) then
                table.remove(result, i)
            end
        end
    end

    return result
end

local function liveHitboxAwareShapecast(player: Player, part: Part, direction: Vector3, params: RaycastParams?, check: ((BasePart) -> boolean)?): RaycastResult?
    local blanket = RaycastParams.new()
    if params then
        if params.ExcludeInstances then
            blanket.ExcludeInstances = params.ExcludeInstances
        end
        if params.IncludeInstances then
            blanket.IncludeInstances = params.IncludeInstances
        end
        if params.RespectCanCollide ~= nil then
            blanket.RespectCanCollide = params.RespectCanCollide
        end
    end
    if params and params.CollisionGroup and CentralServer.IsQueryGroup(params.CollisionGroup) then
        blanket.CollisionGroup = params.CollisionGroup
    else
        blanket.CollisionGroup = Settings.DEFAULT_HITBOX_QUERY_GROUP
    end

    local result: RaycastResult?
    if check then
        result = shapecastExcludeRetry(part, direction, blanket, check)
    else
        result = workspace:Shapecast(part, direction, blanket)
    end

    local owned = CentralServer.GetOwnedHitboxParts(player)
    if #owned > 0 then
        local ownedParams = RaycastParams.new()
        if params then
            if params.ExcludeInstances then
                ownedParams.ExcludeInstances = params.ExcludeInstances
            end
            if params.CollisionGroup then
                ownedParams.CollisionGroup = params.CollisionGroup
            end
            if params.RespectCanCollide ~= nil then
                ownedParams.RespectCanCollide = params.RespectCanCollide
            end
        end
        ownedParams.IncludeInstances = filterByInclude(owned, if params then params.IncludeInstances else nil)

        local ownedResult: RaycastResult?
        if check then
            ownedResult = shapecastExcludeRetry(part, direction, ownedParams, check)
        else
            ownedResult = workspace:Shapecast(part, direction, ownedParams)
        end

        if ownedResult and (not result or ownedResult.Distance < result.Distance) then
            result = ownedResult
        end
    end

    return result
end

function Central.Raycast(player:Player, origin:Vector3, direction:Vector3, raycastParams:RaycastParams?, querySettings: QueryConfiguration?) : (number?,BasePart?, Vector3?, Vector3?)
    local distance:number?, instance:BasePart?, position:Vector3?, normal:Vector3?
    local check = querySettings and querySettings.check

    if isServer then
        local raycastResult, raycastDistanceOverride = liveHitboxAwareRaycast(player, origin, direction, raycastParams, check)
        if raycastResult then
            distance = raycastDistanceOverride or raycastResult.Distance
            instance = raycastResult.Instance
            position = raycastResult.Position
            normal = raycastResult.Normal
        end
    else
        local raycastResult = workspace:Raycast(origin, direction, raycastParams)
        if raycastResult then
            distance = raycastResult.Distance
            instance = raycastResult.Instance
            position = raycastResult.Position
            normal = raycastResult.Normal
        end
    end

    if isServer then
        local newDirection = if distance then direction.Unit*(distance+RAYCAST_MARGIN)  else direction

        local hitbox, hitPoint, hitDistance, hitNormal = CentralServer.QueryPlayerRaycast(player, origin, newDirection, querySettings and querySettings.frameRange, raycastParams, check)
        if hitbox and (not check or not distance or (hitDistance :: number) < distance) then
            distance = hitDistance
            instance = hitbox.instance
            position = hitPoint
            normal = hitNormal
        end
    end

    if DEBUG_MODE then
        pushDebugDraw(function()
            visualizer.next_color(DEBUG_RAY_COLOR)
            visualizer.components.ray(origin, origin + direction)

            if instance then
                visualizer.next_color(DEBUG_HIT_COLOR)
                visualizer.components.box(instance.CFrame, bolt.create_box(instance.Size))
            end
        end)
    end

    return distance, instance, position, normal
end

function Central.Shapecast(player:Player, part:Part, direction:Vector3, raycastParams:RaycastParams?, querySettings: QueryConfiguration?) : (number?, BasePart?, Vector3?, Vector3?)
    local distance:number?, instance:BasePart?, position:Vector3?, normal:Vector3?
    local check = querySettings and querySettings.check

    local castResult = if isServer
        then liveHitboxAwareShapecast(player, part, direction, raycastParams, check)
        else workspace:Shapecast(part, direction, raycastParams)
    if castResult then
        distance = castResult.Distance
        instance = castResult.Instance
        position = castResult.Position
        normal = castResult.Normal
    end

    if isServer then
        local newDirection = if distance then direction.Unit*(distance+RAYCAST_MARGIN) else direction

        local hitbox, hitPoint, hitDistance, hitNormal = CentralServer.QueryPlayerShapecast(player, part.CFrame, bolt.create_from_part(part), newDirection, querySettings and querySettings.frameRange, raycastParams, check)
        if hitbox and (not check or not distance or (hitDistance :: number) < distance) then
            distance = hitDistance
            instance = hitbox.instance
            position = hitPoint
            normal = hitNormal
        end
    end

    if DEBUG_MODE then
        pushDebugDraw(function()
            visualizer.next_color(DEBUG_RAY_COLOR)
            visualizer.components.box(part.CFrame, bolt.create_box(part.Size))
            visualizer.components.ray(part.Position, part.Position + direction)

            if instance then
                visualizer.next_color(DEBUG_HIT_COLOR)
                visualizer.components.box(instance.CFrame, bolt.create_box(instance.Size))
            end
        end)
    end

    return distance, instance, position, normal
end

function Central.SimpleShapecast(player:Player, part:Part, direction:Vector3, raycastParams:RaycastParams?, querySettings: QueryConfiguration?) : (number?, BasePart?)
    local distance:number?, instance:BasePart?
    local check = querySettings and querySettings.check

    local castResult = if isServer
        then liveHitboxAwareShapecast(player, part, direction, raycastParams, check)
        else workspace:Shapecast(part, direction, raycastParams)
    if castResult then
        distance = castResult.Distance
        instance = castResult.Instance
    end

    if isServer then
        local newDirection = if distance then direction.Unit*(distance+RAYCAST_MARGIN) else direction

        local hitbox, hitDistance = CentralServer.QueryPlayerSimpleShapecast(player, part.CFrame, bolt.create_from_part(part), newDirection, querySettings and querySettings.frameRange, raycastParams, check)
        if hitbox and (not check or not distance or (hitDistance :: number) < distance) then
            distance = hitDistance
            instance = hitbox.instance
        end
    end

    if DEBUG_MODE then
        pushDebugDraw(function()
            visualizer.next_color(DEBUG_RAY_COLOR)
            visualizer.components.box(part.CFrame, bolt.create_box(part.Size))
            visualizer.components.ray(part.Position, part.Position + direction)

            if instance then
                visualizer.next_color(DEBUG_HIT_COLOR)
                visualizer.components.box(instance.CFrame, bolt.create_box(instance.Size))
            end
        end)
    end

    return distance, instance
end

function Central.GetBoundsInRadius(player:Player, position:Vector3, radius:number, overlapParams:OverlapParams?, querySettings: QueryConfiguration?) : {BasePart}
    local result = if isServer
        then liveHitboxAwareOverlap(player, function(p) return workspace:GetPartBoundsInRadius(position, radius, p) end, overlapParams, querySettings and querySettings.check)
        else workspace:GetPartBoundsInRadius(position, radius, overlapParams)


    if isServer then
        local serverResult = CentralServer.QueryPlayerShape(player, CFrame.new(position), bolt.create_sphere(radius), querySettings and querySettings.frameRange, overlapParams, querySettings and querySettings.check)
        for part,_ in serverResult do
            if not table.find(result, part) then
                table.insert(result, part)
            end
        end
    end

    if DEBUG_MODE and #result > 0 then
        pushDebugDraw(function()
            visualizer.next_color(DEBUG_RAY_COLOR)
            visualizer.components.sphere(position, bolt.create_sphere(radius))

            visualizer.next_color(DEBUG_HIT_COLOR)
            for _, part in result do
                visualizer.components.box(part.CFrame, bolt.create_box(part.Size))
            end
        end)
    end

    return result
end

function Central.GetPartBoundsInBox(player:Player, cframe:CFrame, size:Vector3, overlapParams:OverlapParams?, querySettings: QueryConfiguration?) : {BasePart}
    local result = if isServer
        then liveHitboxAwareOverlap(player, function(p) return workspace:GetPartBoundsInBox(cframe, size, p) end, overlapParams, querySettings and querySettings.check)
        else workspace:GetPartBoundsInBox(cframe, size, overlapParams);


    if isServer then
        local serverResult = CentralServer.QueryPlayerShape(player, cframe, bolt.create_box(size), querySettings and querySettings.frameRange, overlapParams, querySettings and querySettings.check)
        for part,_ in serverResult do
            if not table.find(result, part) then
                table.insert(result, part)
            end
        end
    end

    if DEBUG_MODE and #result > 0 then
        pushDebugDraw(function()
            visualizer.next_color(DEBUG_RAY_COLOR)
            visualizer.components.box(cframe, bolt.create_box(size))

            visualizer.next_color(DEBUG_HIT_COLOR)
            for _, part in result do
                visualizer.components.box(part.CFrame, bolt.create_box(part.Size))
            end
        end)
    end

    return result
end

function Central.GetPartsInPart(player:Player, part:Part, overlapParams:OverlapParams?, querySettings: QueryConfiguration?) : {BasePart}
    local result = if isServer
        then liveHitboxAwareOverlap(player, function(p) return workspace:GetPartsInPart(part, p) end, overlapParams, querySettings and querySettings.check)
        else workspace:GetPartsInPart(part, overlapParams)

    if isServer then
        local serverResult = CentralServer.QueryPlayerShape(player, part.CFrame, bolt.create_from_part(part), querySettings and querySettings.frameRange, overlapParams, querySettings and querySettings.check)
        for otherPart,_ in serverResult do
            if not table.find(result, otherPart) then
                table.insert(result, otherPart)
            end
        end
    end

    if DEBUG_MODE and #result > 0 then
        pushDebugDraw(function()
            visualizer.next_color(DEBUG_RAY_COLOR)
            visualizer.components.box(part.CFrame, bolt.create_box(part.Size))

            visualizer.next_color(DEBUG_HIT_COLOR)
            for _, otherPart in result do
                visualizer.components.box(otherPart.CFrame, bolt.create_box(otherPart.Size))
            end
        end)
    end

    return result
end

return Central
