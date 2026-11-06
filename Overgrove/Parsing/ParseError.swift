/// A parser rejected git or gh output (parsing-spec.md §1.6).
///
/// Parsers fail as a whole instead of guessing: reading on after a misaligned field would show wrong information.
/// `GitError` maps this to `parseFailed(parser:offset:)`.
struct ParseError: Error, Equatable {
    /// Parser name, e.g. `ConfigParser`.
    let parser: String
    /// Byte offset (or record index for JSON) where parsing stopped.
    let offset: Int
    let reason: String
}
