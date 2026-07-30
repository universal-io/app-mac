/// Bridges staged text to the destination selected when Compose opened.
protocol Deployer {
    func deploy(_ text: String) throws
}
