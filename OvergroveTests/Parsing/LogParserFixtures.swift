import Foundation

/// Real `git log -z` output (Apple Git 2.54.0) for PAR-LOG-xx. All commits use `t <t@example.com>` at 1793853652
/// except one by `김개발 <dev@example.com>` at 1793853700.
///
/// History, newest first (`--topo-order`): `feat: subject line` (multi-line body) → empty subject →
/// `한글 제목 🌳 émoji` → `octopus` (parents: merge, b, c) → `c` → `Merge branch 'other'` (parents: a, b) → `b`, `a`
/// → `root`.
/// A fixture that fails to decode becomes empty data, which every test below rejects.
enum LogParserFixtures {
    /// `log --topo-order -z` in the graph format (`ReadOnlyGitCommand.logFormat`) in a SHA-1 repository. None of these
    /// commits has a co-author trailer, so the last field of every record is empty.
    static let sha1Graph =
        Data(
            base64Encoded:
                "MGQyOTdiZTgwMGE1YjQ5YWI5ZjRjYzUxZTUxNmI3MWNkMGE1NjUwNAA2Y2I1NmU5NGVmZjBkNTAzMTFkYzkxZmFlYTUwOWE2ZDdmMjg1MGE5AHQAdEBleGFtcGxlLmNvbQAxNzkzODUzNjUyAGZlYXQ6IHN1YmplY3QgbGluZQAANmNiNTZlOTRlZmYwZDUwMzExZGM5MWZhZWE1MDlhNmQ3ZjI4NTBhOQAxYWQ4MDY2NTViYzEyZGIxYzIxZmM5N2ViYmFkMzcyMzU2ODUwZmYxAHQAdEBleGFtcGxlLmNvbQAxNzkzODUzNjUyAAAAMWFkODA2NjU1YmMxMmRiMWMyMWZjOTdlYmJhZDM3MjM1Njg1MGZmMQA1OTc4NGMwNGYyNWFhYjQ3YWM3YmQ2OGMzNDNkZDU3YjNlNDUzZGI3AOq5gOqwnOuwnABkZXZAZXhhbXBsZS5jb20AMTc5Mzg1MzcwMADtlZzquIAg7KCc66qpIPCfjLMgw6ltb2ppAAA1OTc4NGMwNGYyNWFhYjQ3YWM3YmQ2OGMzNDNkZDU3YjNlNDUzZGI3AGZkNjc1M2FkMmMyZGUxMzc2NjdlNDViNTIxZDJkZTllMmM5ZjM2NTggM2Y0NmQxMjExMmM0N2ZhMWJlMzMzYTc4OWY4MGI2YjBkMmJkODVlMyBmN2NiMDgzOTk1OTYyMWM2ZjE3ZTI3MzBlMDA1ZjBhMjA4MGNlNDg2AHQAdEBleGFtcGxlLmNvbQAxNzkzODUzNjUyAG9jdG9wdXMAAGY3Y2IwODM5OTU5NjIxYzZmMTdlMjczMGUwMDVmMGEyMDgwY2U0ODYANGU2ODIzYTZmYmQyMjQ3OWQ3YWUzMjA5ZWNhM2JkZDk2ZTkxMDU5ZQB0AHRAZXhhbXBsZS5jb20AMTc5Mzg1MzY1MgBjAABmZDY3NTNhZDJjMmRlMTM3NjY3ZTQ1YjUyMWQyZGU5ZTJjOWYzNjU4ADAxOTc2NmE0M2FiZjcyM2JiMDkxMDg0MGEwMTk0MmQ4YjA1ZjJjOTAgM2Y0NmQxMjExMmM0N2ZhMWJlMzMzYTc4OWY4MGI2YjBkMmJkODVlMwB0AHRAZXhhbXBsZS5jb20AMTc5Mzg1MzY1MgBNZXJnZSBicmFuY2ggJ290aGVyJwAAM2Y0NmQxMjExMmM0N2ZhMWJlMzMzYTc4OWY4MGI2YjBkMmJkODVlMwA0ZTY4MjNhNmZiZDIyNDc5ZDdhZTMyMDllY2EzYmRkOTZlOTEwNTllAHQAdEBleGFtcGxlLmNvbQAxNzkzODUzNjUyAGIAADAxOTc2NmE0M2FiZjcyM2JiMDkxMDg0MGEwMTk0MmQ4YjA1ZjJjOTAANGU2ODIzYTZmYmQyMjQ3OWQ3YWUzMjA5ZWNhM2JkZDk2ZTkxMDU5ZQB0AHRAZXhhbXBsZS5jb20AMTc5Mzg1MzY1MgBhAAA0ZTY4MjNhNmZiZDIyNDc5ZDdhZTMyMDllY2EzYmRkOTZlOTEwNTllAAB0AHRAZXhhbXBsZS5jb20AMTc5Mzg1MzY1MgByb290AAA="
        ) ?? Data()

    /// The same history in a `--object-format=sha256` repository.
    static let sha256Graph =
        Data(
            base64Encoded:
                "M2VhYjJlZWU3ZGFlNzZiYjhhZmMxMThlZjllYTA3ODQ4YjI4NzAyZjNiNTY5MzFjMmQwNTllNjhkYTYzOTY4OABlNTczZDg0NzRlOTI2NjkwYjZhYTk2MjZjZTcyOGE4MTBlZWZkMDM4ZTIzMmE0ZTE2YzQzOGRiNjFlM2I4MmFiAHQAdEBleGFtcGxlLmNvbQAxNzkzODUzNjUyAGZlYXQ6IHN1YmplY3QgbGluZQAAZTU3M2Q4NDc0ZTkyNjY5MGI2YWE5NjI2Y2U3MjhhODEwZWVmZDAzOGUyMzJhNGUxNmM0MzhkYjYxZTNiODJhYgBiMDM3NTQ4Yjc0MGU2NmI0NTM3YjJhNzU4YzMxYWFkNjMwNWYxZTgxZWQyZDQ4NzM1OTk5YmY0NjlhNGJhNzllAHQAdEBleGFtcGxlLmNvbQAxNzkzODUzNjUyAAAAYjAzNzU0OGI3NDBlNjZiNDUzN2IyYTc1OGMzMWFhZDYzMDVmMWU4MWVkMmQ0ODczNTk5OWJmNDY5YTRiYTc5ZQBhNTg4NjQ3ZDMyZjAyNGExMmQ5NjA4Njk0MjNmY2YyNzAyOTE0NDBjNjBlYTFlMzkzNTYzZGE4OWMxOGFhNTZhAOq5gOqwnOuwnABkZXZAZXhhbXBsZS5jb20AMTc5Mzg1MzcwMADtlZzquIAg7KCc66qpIPCfjLMgw6ltb2ppAABhNTg4NjQ3ZDMyZjAyNGExMmQ5NjA4Njk0MjNmY2YyNzAyOTE0NDBjNjBlYTFlMzkzNTYzZGE4OWMxOGFhNTZhAGNjNWQwZDk1NmEwMWU3MmVlZWI1Njk2MjdmZTg2ODczYTM2ZWFiODM0NjQ0OTg2MTMwYmFkMzAyZjY3OTNlNjQgYTdkYmRlZTM1N2JlYjZlNDU2NjYwMTUxNmFiZjEwZjEzMzI0MWM5ODFlNGY0YmM0YjcwMzEwNmFiNjQ5NDgxNyBkYTU4ODEyZGY1NjE4MzRlZTU1MTA2NmU5OWZiYzZjMzczNTQ3ODQ3YWM5YTJhOGUwMWUxYTViZWI5NjM0YmZhAHQAdEBleGFtcGxlLmNvbQAxNzkzODUzNjUyAG9jdG9wdXMAAGRhNTg4MTJkZjU2MTgzNGVlNTUxMDY2ZTk5ZmJjNmMzNzM1NDc4NDdhYzlhMmE4ZTAxZTFhNWJlYjk2MzRiZmEAZmNhNGUwMmZlYzJlOTJmZTY2YmVjZWQwYzhkZTQ0ZWNmMjEyNWI2OGIwMzIxZTgyZTQwOGUwZDQzZGE1NTM4NAB0AHRAZXhhbXBsZS5jb20AMTc5Mzg1MzY1MgBjAABjYzVkMGQ5NTZhMDFlNzJlZWViNTY5NjI3ZmU4Njg3M2EzNmVhYjgzNDY0NDk4NjEzMGJhZDMwMmY2NzkzZTY0ADNmYjQ5ODliNmMxOWU2ZGRjNmRhNjFhNThmNGMyZGFjNjFiZWFhNmIzZDRlMzRmODgxNmQ4ZWVkYjUwNGQ0MTIgYTdkYmRlZTM1N2JlYjZlNDU2NjYwMTUxNmFiZjEwZjEzMzI0MWM5ODFlNGY0YmM0YjcwMzEwNmFiNjQ5NDgxNwB0AHRAZXhhbXBsZS5jb20AMTc5Mzg1MzY1MgBNZXJnZSBicmFuY2ggJ290aGVyJwAAYTdkYmRlZTM1N2JlYjZlNDU2NjYwMTUxNmFiZjEwZjEzMzI0MWM5ODFlNGY0YmM0YjcwMzEwNmFiNjQ5NDgxNwBmY2E0ZTAyZmVjMmU5MmZlNjZiZWNlZDBjOGRlNDRlY2YyMTI1YjY4YjAzMjFlODJlNDA4ZTBkNDNkYTU1Mzg0AHQAdEBleGFtcGxlLmNvbQAxNzkzODUzNjUyAGIAADNmYjQ5ODliNmMxOWU2ZGRjNmRhNjFhNThmNGMyZGFjNjFiZWFhNmIzZDRlMzRmODgxNmQ4ZWVkYjUwNGQ0MTIAZmNhNGUwMmZlYzJlOTJmZTY2YmVjZWQwYzhkZTQ0ZWNmMjEyNWI2OGIwMzIxZTgyZTQwOGUwZDQzZGE1NTM4NAB0AHRAZXhhbXBsZS5jb20AMTc5Mzg1MzY1MgBhAABmY2E0ZTAyZmVjMmU5MmZlNjZiZWNlZDBjOGRlNDRlY2YyMTI1YjY4YjAzMjFlODJlNDA4ZTBkNDNkYTU1Mzg0AAB0AHRAZXhhbXBsZS5jb20AMTc5Mzg1MzY1MgByb290AAA="
        ) ?? Data()

    /// `log -1 -z --format=%H%x00%P%x00%an%x00%ae%x00%at%x00%cn%x00%ce%x00%ct%x00%B` for `feat: subject line`.
    static let sha1Detail =
        Data(
            base64Encoded:
                "MGQyOTdiZTgwMGE1YjQ5YWI5ZjRjYzUxZTUxNmI3MWNkMGE1NjUwNAA2Y2I1NmU5NGVmZjBkNTAzMTFkYzkxZmFlYTUwOWE2ZDdmMjg1MGE5AHQAdEBleGFtcGxlLmNvbQAxNzkzODUzNjUyAHQAdEBleGFtcGxlLmNvbQAxNzkzODUzNjUyAGZlYXQ6IHN1YmplY3QgbGluZQoKQm9keSBmaXJzdCBsaW5lCiAgaW5kZW50ZWQKClJlZnM6ICM1MwoA"
        ) ?? Data()

    /// Graph format (empty co-author field) for a commit made with `hash-object --literally` whose message is
    /// `before␀after⏎`.
    static let nulMessageGraph =
        Data(
            base64Encoded:
                "ZWZkMTk5OGNhZGQ3OGVjZjU4NmIxOWQyNGIyYjNkN2VlNjUwYWNiMwAAdAB0QGV4YW1wbGUuY29tADE3OTM4NTM2NTIAYmVmb3JlAAA="
        ) ?? Data()

    /// Detail format for the same commit.
    static let nulMessageDetail =
        Data(
            base64Encoded:
                "ZWZkMTk5OGNhZGQ3OGVjZjU4NmIxOWQyNGIyYjNkN2VlNjUwYWNiMwAAdAB0QGV4YW1wbGUuY29tADE3OTM4NTM2NTIAdAB0QGV4YW1wbGUuY29tADE3OTM4NTM2NTIAYmVmb3JlAA=="
        ) ?? Data()

    /// Graph format with co-author trailers (Apple Git 2.54.0, PAR-LOG-09), newest first:
    /// `mid-text mention` (a `Co-authored-by:` line inside a paragraph, not a trailer) → `folded` (one trailer folded
    /// over two lines) → `human and AI` (`Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>` and
    /// `co-authored-by: Alice <alice@example.com>`, plus a `Signed-off-by:`) → `plain` (root, no trailers).
    static let coAuthorGraph =
        Data(
            base64Encoded:
                "MTE1MTQyZmQ3MWZjNTIwYmY1ZDgzZDg4ZWY3ZGNlMGNjMDJmOGEyMwA3YTlhNDMzNGFiMDViZDRiZDExOTY4MGIyZmJmMzBjYjZjZDM0MjUzAHQAdEBleGFtcGxlLmNvbQAxNzkzODUzNjUyAG1pZC10ZXh0IG1lbnRpb24AADdhOWE0MzM0YWIwNWJkNGJkMTE5NjgwYjJmYmYzMGNiNmNkMzQyNTMANGYyZWIyMjJhOTBiZjMwZTM3OWZlYTQ3Zjg0YmM3Mzc4NDYzYWZkZQB0AHRAZXhhbXBsZS5jb20AMTc5Mzg1MzY1MgBmb2xkZWQAQm9iIENvbnRpbnVlZCA8Ym9iQGV4YW1wbGUuY29tPgA0ZjJlYjIyMmE5MGJmMzBlMzc5ZmVhNDdmODRiYzczNzg0NjNhZmRlADMwNmY1N2ZhOGM2MWNkZTEzNWRjMjRmZGNiY2I5Mjk2M2E3OGRlNzQAdAB0QGV4YW1wbGUuY29tADE3OTM4NTM2NTIAaHVtYW4gYW5kIEFJAENsYXVkZSBPcHVzIDUuNSA8bm9yZXBseUBhbnRocm9waWMuY29tPh9BbGljZSA8YWxpY2VAZXhhbXBsZS5jb20+ADMwNmY1N2ZhOGM2MWNkZTEzNWRjMjRmZGNiY2I5Mjk2M2E3OGRlNzQAAHQAdEBleGFtcGxlLmNvbQAxNzkzODUzNjUyAHBsYWluAAA="
        ) ?? Data()

    /// `ReadOnlyGitCommand.fileHistory(path: "Status.swift")` output (`log --follow -z … --numstat`, Apple Git 2.54.0).
    /// History, newest first: `chore: make it binary` (`-\t-`) → `main: capitalize d` and `side: capitalize a` (1/1
    /// each; their merge is not listed) → `refactor: rename to Status.swift` (1/0, rename from `Parser.swift`) →
    /// `feat: add c` (1/0, `Parser.swift`) → `chore: bootstrap` (2/0, root).
    static let fileHistory =
        Data(
            base64Encoded:
                "NzFkNzQzZGU1YTQwMWQ1MjYzM2JhNDU0MzU3NzFhN2I3MWJhZjUxMgA4ODRlZDZkZDM2N2Y2ZDQ0NDQwN2RiYTI3ZDhhMzQ5ODAzMGVlZDZhAHQAdEBleGFtcGxlLmNvbQAxNzkzODUzNjUyAGNob3JlOiBtYWtlIGl0IGJpbmFyeQAACi0JLQlTdGF0dXMuc3dpZnQAOTg2OTg0ZTM1MGU5OTc2OTI1NTU0Y2YxZmIzNjA0YTYxYmVkM2ZmNQA0YThiNTQxM2M3ZmI1ZGM2OTE1NTZhODVhYzVlMmFjMTE5MzZlOWZjAHQAdEBleGFtcGxlLmNvbQAxNzkzODUzNjUyAG1haW46IGNhcGl0YWxpemUgZAAACjEJMQlTdGF0dXMuc3dpZnQAZTIwMDYxZTRlYzFkZjQxNjEzZmU5NGEwNWFkM2M2MjFlZDAyOWM3ZQA0YThiNTQxM2M3ZmI1ZGM2OTE1NTZhODVhYzVlMmFjMTE5MzZlOWZjAHQAdEBleGFtcGxlLmNvbQAxNzkzODUzNjUyAHNpZGU6IGNhcGl0YWxpemUgYQAACjEJMQlTdGF0dXMuc3dpZnQANGE4YjU0MTNjN2ZiNWRjNjkxNTU2YTg1YWM1ZTJhYzExOTM2ZTlmYwAzNTZlMmYyOTUwZjY5OTQ3YzEwZDNjY2VkZjBkZDA4MmUyNWNiZWEwAHQAdEBleGFtcGxlLmNvbQAxNzkzODUzNjUyAHJlZmFjdG9yOiByZW5hbWUgdG8gU3RhdHVzLnN3aWZ0AAAKMQkwCQBQYXJzZXIuc3dpZnQAU3RhdHVzLnN3aWZ0ADM1NmUyZjI5NTBmNjk5NDdjMTBkM2NjZWRmMGRkMDgyZTI1Y2JlYTAAYTI3NGM1NWQzMTA1OTAyOWIxYTMzMWQxYWUzZWRmYTliNjg0MDBiZgB0AHRAZXhhbXBsZS5jb20AMTc5Mzg1MzY1MgBmZWF0OiBhZGQgYwAACjEJMAlQYXJzZXIuc3dpZnQAYTI3NGM1NWQzMTA1OTAyOWIxYTMzMWQxYWUzZWRmYTliNjg0MDBiZgAAdAB0QGV4YW1wbGUuY29tADE3OTM4NTM2NTIAY2hvcmU6IGJvb3RzdHJhcAAACjIJMAlQYXJzZXIuc3dpZnQA"
        ) ?? Data()
}
