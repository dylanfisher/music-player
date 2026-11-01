/// Every benchmark, in the order `scripts/bench` runs them. A phase adds its benchmarks in a
/// file named for the module they measure, with their budgets, and lists them here.
let benchmarks =
    settingsBenchmarks + fixtureBenchmarks + metadataBenchmarks + libraryBenchmarks
    + moveBenchmarks + syncBenchmarks
    + healthBenchmarks + playlistBenchmarks + historyBenchmarks + windowBenchmarks
    + paletteBenchmarks
    + playbackBenchmarks
    + tagWriterBenchmarks
