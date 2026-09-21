# How deployment dispatch works

Each `model-PROFILE` flake output exports an immutable profile name, the checked-in registry path, and the correct topology launcher. `scripts/launch-model.sh` reads that metadata and dispatches to the Solo, Deuces, Trips, Quads, or Eights coordinator.

The shell is inert. The `qualify-and-serve` action checks the model revision and weight tree, pinned runtime image, DGX Spark hardware, topology binding, and prior acceptance boundary before keeping a loopback service in the foreground. Multi-node coordinators fail closed and clean up resources they own.
