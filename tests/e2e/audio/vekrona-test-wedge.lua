-- Test only. An async hook that never completes, the way the V4L2 monitor's did for a device that vanished mid-activation:
-- WirePlumber's event dispatcher waits for it forever and ignores every event queued behind it.
AsyncEventHook {
  name = "vekrona-test/wedge",
  interests = {
    EventInterest {
      Constraint { "event.type", "=", "device-removed" },
    },
  },
  steps = {
    start = {
      next = "none",
      execute = function (event, transition)
      end,
    },
  },
}:register ()
