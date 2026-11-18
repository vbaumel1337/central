--!strict
-- The implementations the automated benchmark (bench/autobench.py) and the differential gate can
-- be pointed at, by name. Takes the `central` package instance and returns name -> how to build.
--
-- "Current" is whatever lib/CentralServer/HistoricalHitboxes is right now, built the way
-- lib/CentralServer/init.luau builds it. WHEN THAT CONSTRUCTOR CALL CHANGES, CHANGE IT HERE TOO:
-- this is the one place the benchmark tooling knows a constructor signature.
--
-- "Ref" is the frozen one-tree-per-frame original. It never changes, which makes it the control:
-- a run-to-run shift in Ref's numbers is the machine, not the code.
--
-- Anything else is optional and only listed while its module exists, so a comparison
-- implementation can be added or deleted without touching the tooling.
export type Implementation = {
	name: string,
	frameCap: number,
	new: () -> any,
}

return function(central: Instance): {[string]: Implementation}
	local Settings = require((central :: any).Settings) :: any
	local server = (central :: any).CentralServer :: Instance

	local list: {[string]: Implementation} = {}

	local current = require((server :: any).HistoricalHitboxes) :: any
	list.Current = {
		name = "Current",
		frameCap = Settings.FRAME_CAP,
		new = function()
			return current.new(Settings.FRAME_CAP, Settings.AABB_PADDING, Settings.TEMPORAL_BUCKETS)
		end,
	}

	local refModule = server:FindFirstChild("HistoricalHitboxesRef")
	if refModule then
		local ref = require(refModule :: any) :: any
		-- master's settings exactly (FRAME_CAP = 60, AABB_PADDING = 1), the ones it shipped with
		list.Ref = {
			name = "Ref",
			frameCap = 60,
			new = function()
				return ref.new(60, 1)
			end,
		}
	end

	-- a snapshot of Current from before the work being measured, for a same-run A/B. Only present
	-- while that module is in the tree.
	local beforeModule = server:FindFirstChild("HistoricalHitboxesBefore")
	if beforeModule then
		local before = require(beforeModule :: any) :: any
		list.Before = {
			name = "Before",
			frameCap = Settings.FRAME_CAP,
			new = function()
				return before.new(Settings.FRAME_CAP, Settings.AABB_PADDING, Settings.TEMPORAL_BUCKETS)
			end,
		}
	end

	local unionModule = server:FindFirstChild("HistoricalHitboxesUnion")
	if unionModule then
		local union = require(unionModule :: any) :: any
		-- the per-block union trees, at the settings last tuned for them
		list.Union = {
			name = "Union",
			frameCap = 60,
			new = function()
				return union.new(6, 10, 1, 16, 0.5)
			end,
		}
	end

	return list
end
