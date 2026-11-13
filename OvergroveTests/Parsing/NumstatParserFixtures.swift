import Foundation

/// Real output (Apple Git 2.50.1) for PAR-NUMSTAT-xx, captured with the exact `commitFiles` arguments
/// (`diff-tree -r -z --raw --numstat -M --no-ext-diff --no-textconv --no-commit-id --root`) and `stashFiles` arguments
/// (`stash show --include-untracked -z --raw --numstat -M --no-abbrev --no-ext-diff --no-textconv`; the stash
/// fixtures were recaptured with Apple Git 2.54.0 for #602). ␉ is a tab, ␀ a NUL.
/// A fixture that fails to decode becomes empty data, which the tests below would notice as missing files.
enum NumstatParserFixtures {
    /// `root`: four files added. Needs `--root`, which `commitFiles` always passes.
    static let rootCommit =
        Data(
            base64Encoded:
                "OjAwMDAwMCAxMDA2NDQgMDAwMDAwMDAwMDAwMDAwMDAwMDAwMDAwMDAwMDAwMDAwMDAwMDAwMCBiM2M1YTk1ZjkyOWE1MGZlYjA2YzI3NWFjNTY3Y2RiMWI0NDFkMWUyIEEAZ3VpZGUubWQAOjAwMDAwMCAxMDA2NDQgMDAwMDAwMDAwMDAwMDAwMDAwMDAwMDAwMDAwMDAwMDAwMDAwMDAwMCA0Y2IyOWVhMzhmNzBkN2M2MWIyYTNhMjViMDJlM2JkZjQ0OTA1NDAyIEEAa2VlcC50eHQAOjAwMDAwMCAxMDA2NDQgMDAwMDAwMDAwMDAwMDAwMDAwMDAwMDAwMDAwMDAwMDAwMDAwMDAwMCA1ODdiZTZiNGMzZjkzZjkzYzQ4OWMwMTExYmJhNTU5NjE0N2EyNmNiIEEAbGluay10YXJnZXQAOjAwMDAwMCAxMDA2NDQgMDAwMDAwMDAwMDAwMDAwMDAwMDAwMDAwMDAwMDAwMDAwMDAwMDAwMCAyODZjNWY1Nzc2OTE2ZDdkN2Q1ODQ5OTg4Y2E5ZDgzZTcyMmNmOWMyIEEAb2xkLnR4dAA1CTAJZ3VpZGUubWQAMwkwCWtlZXAudHh0ADEJMAlsaW5rLXRhcmdldAAxCTAJb2xkLnR4dAA="
        ) ?? Data()

    /// `keep.txt` modified (+2 −1), `new file.txt` added (+2), `old.txt` deleted (−1).
    static let addModifyDelete =
        Data(
            base64Encoded:
                "OjEwMDY0NCAxMDA2NDQgNGNiMjllYTM4ZjcwZDdjNjFiMmEzYTI1YjAyZTNiZGY0NDkwNTQwMiA2YWRkYjliN2M3NTNhYTEyY2RjNmMwZjIyZDdjN2ZlNGI0M2VjOGViIE0Aa2VlcC50eHQAOjAwMDAwMCAxMDA2NDQgMDAwMDAwMDAwMDAwMDAwMDAwMDAwMDAwMDAwMDAwMDAwMDAwMDAwMCAwN2YzM2M0MTljOGRmMTc3OTE5Y2RmNzFjNjcwZTQ1ODdmMWI2NDVmIEEAbmV3IGZpbGUudHh0ADoxMDA2NDQgMDAwMDAwIDI4NmM1ZjU3NzY5MTZkN2Q3ZDU4NDk5ODhjYTlkODNlNzIyY2Y5YzIgMDAwMDAwMDAwMDAwMDAwMDAwMDAwMDAwMDAwMDAwMDAwMDAwMDAwMCBEAG9sZC50eHQAMgkxCWtlZXAudHh0ADIJMAluZXcgZmlsZS50eHQAMAkxCW9sZC50eHQA"
        ) ?? Data()

    /// `guide.md` → `docs/manual.md` without edits (`R100`, numstat `0␉0␉␀old␀new␀`).
    static let pureRename =
        Data(
            base64Encoded:
                "OjEwMDY0NCAxMDA2NDQgYjNjNWE5NWY5MjlhNTBmZWIwNmMyNzVhYzU2N2NkYjFiNDQxZDFlMiBiM2M1YTk1ZjkyOWE1MGZlYjA2YzI3NWFjNTY3Y2RiMWI0NDFkMWUyIFIxMDAAZ3VpZGUubWQAZG9jcy9tYW51YWwubWQAMAkwCQBndWlkZS5tZABkb2NzL21hbnVhbC5tZAA="
        ) ?? Data()

    /// `docs/manual.md` → `docs/guide-v2.md` with one line added (`R083`).
    static let renameWithEdit =
        Data(
            base64Encoded:
                "OjEwMDY0NCAxMDA2NDQgYjNjNWE5NWY5MjlhNTBmZWIwNmMyNzVhYzU2N2NkYjFiNDQxZDFlMiA1ZmNiN2IxYjNjYTQwODM5ZDc2NzNlZWQxN2FmZGIwYTIyMTQzMmNlIFIwODMAZG9jcy9tYW51YWwubWQAZG9jcy9ndWlkZS12Mi5tZAAxCTAJAGRvY3MvbWFudWFsLm1kAGRvY3MvZ3VpZGUtdjIubWQA"
        ) ?? Data()

    /// `assets/binary.bin` added; numstat prints `-␉-`.
    static let binaryAdd =
        Data(
            base64Encoded:
                "OjAwMDAwMCAxMDA2NDQgMDAwMDAwMDAwMDAwMDAwMDAwMDAwMDAwMDAwMDAwMDAwMDAwMDAwMCBiZmE3MDE4ZTMwYzUxMDk5OWJiZTQ2MjMxNmJkZDM4MzlhNThhYTU2IEEAYXNzZXRzL2JpbmFyeS5iaW4ALQktCWFzc2V0cy9iaW5hcnkuYmluAA=="
        ) ?? Data()

    /// `link-target` turned from a regular file into a symlink (`T`, `100644` → `120000`).
    static let typeChange =
        Data(
            base64Encoded:
                "OjEwMDY0NCAxMjAwMDAgNTg3YmU2YjRjM2Y5M2Y5M2M0ODljMDExMWJiYTU1OTYxNDdhMjZjYiAxNzY0MzI1YWE5OTdiNzllNmY3NGRhODUwZmFjZWY4NjI2MTgxMmUxIFQAbGluay10YXJnZXQAMQkxCWxpbmstdGFyZ2V0AA=="
        ) ?? Data()

    /// Paths `:colon.txt` (starts with `:`), `bad\xFFname.txt` (invalid UTF-8), `tab␉name.txt`, `한글.txt`.
    static let unusualPaths =
        Data(
            base64Encoded:
                "OjAwMDAwMCAxMDA2NDQgMDAwMDAwMDAwMDAwMDAwMDAwMDAwMDAwMDAwMDAwMDAwMDAwMDAwMCA2MTc4MDc5ODIyOGQxN2FmMmQzNGZjZTRjZmJkZjM1NTU2ODMyNDcyIEEAOmNvbG9uLnR4dAA6MDAwMDAwIDEwMDY0NCAwMDAwMDAwMDAwMDAwMDAwMDAwMDAwMDAwMDAwMDAwMDAwMDAwMDAwIGYyYWQ2Yzc2ZjAxMTVhNmJhNWIwMDQ1NmE4NDk4MTBlN2VjMGFmMjAgQQBiYWT/bmFtZS50eHQAOjAwMDAwMCAxMDA2NDQgMDAwMDAwMDAwMDAwMDAwMDAwMDAwMDAwMDAwMDAwMDAwMDAwMDAwMCA3ODk4MTkyMjYxM2IyYWZiNjAyNTA0MmZmNmJkODc4YWMxOTk0ZTg1IEEAdGFiCW5hbWUudHh0ADowMDAwMDAgMTAwNjQ0IDAwMDAwMDAwMDAwMDAwMDAwMDAwMDAwMDAwMDAwMDAwMDAwMDAwMDAgNGJjZmU5OGU2NDBjODI4NDUxMTMxMjY2MGZiODcwOWIwYWZhODg4ZSBBAO2VnOq4gC50eHQAMQkwCTpjb2xvbi50eHQAMQkwCWJhZP9uYW1lLnR4dAAxCTAJdGFiCW5hbWUudHh0ADEJMAntlZzquIAudHh0AA=="
        ) ?? Data()

    /// Binary rename `assets/binary.bin` → `assets/moved.bin` (`-␉-␉␀old␀new␀`), plus `tab␉name.txt` deleted and
    /// `renamed␉tab.txt` added (too small to be paired as a rename).
    static let binaryRename =
        Data(
            base64Encoded:
                "OjEwMDY0NCAxMDA2NDQgYmZhNzAxOGUzMGM1MTA5OTliYmU0NjIzMTZiZGQzODM5YTU4YWE1NiBiZmE3MDE4ZTMwYzUxMDk5OWJiZTQ2MjMxNmJkZDM4MzlhNThhYTU2IFIxMDAAYXNzZXRzL2JpbmFyeS5iaW4AYXNzZXRzL21vdmVkLmJpbgA6MDAwMDAwIDEwMDY0NCAwMDAwMDAwMDAwMDAwMDAwMDAwMDAwMDAwMDAwMDAwMDAwMDAwMDAwIGQ0OWMyZTcyMWI0NGIxMDFiOWI2NWMxZTI4NDcwNjNhMGYwYzUzYjkgQQByZW5hbWVkCXRhYi50eHQAOjEwMDY0NCAwMDAwMDAgNzg5ODE5MjI2MTNiMmFmYjYwMjUwNDJmZjZiZDg3OGFjMTk5NGU4NSAwMDAwMDAwMDAwMDAwMDAwMDAwMDAwMDAwMDAwMDAwMDAwMDAwMDAwIEQAdGFiCW5hbWUudHh0AC0JLQkAYXNzZXRzL2JpbmFyeS5iaW4AYXNzZXRzL21vdmVkLmJpbgAyCTAJcmVuYW1lZAl0YWIudHh0ADAJMQl0YWIJbmFtZS50eHQA"
        ) ?? Data()

    /// `a.txt` → `b.txt` with one line added in a `--object-format=sha256` repository (`R050`, 64-digit OIDs).
    static let sha256Rename =
        Data(
            base64Encoded:
                "OjEwMDY0NCAxMDA2NDQgZjg2MjVlNDNmOWUwNGYyNDI5MWY3N2NkYmU0YzcxYjNjMmEzYjAwMDNmNjA0MTliM2VkMDZhMDU4ZDc2NmM4YiA1NTUzMWFhZTM0YTg2NDhmMTlhMWNkZTZhMzQ4NDQzMmVmZWEzOThjZDcwNWQ1ZTRiMjAxZmQwZmMxZjhkZWQ3IFIwNTAAYS50eHQAYi50eHQAMQkwCQBhLnR4dABiLnR4dAA="
        ) ?? Data()

    /// `stashFiles` output (`stash show --include-untracked -z --raw --numstat -M --no-abbrev`, Apple Git 2.54.0, #602)
    /// for a stash with a staged rename-with-edit (`docs/manual.md` → `docs/handbook.md`, R091), a modified
    /// `keep.txt`, and the untracked files `stash-untracked.txt` and binary `ud/untracked.bin`.
    static let stash =
        Data(
            base64Encoded:
                "OjEwMDY0NCAxMDA2NDQgMGZmM2JiYjljOGJiYTIyOTE2NTRjZDY0MDY3ZmE0MTdmZjU0YzUwOCAzMDc4MTA1MTk4YjM5YjBiMmEy"
                + "NWZmNjZkNTc1M2M5NTU0Y2UxZjE5IFIwOTEAZG9jcy9tYW51YWwubWQAZG9jcy9oYW5kYm9vay5tZAA6MTAwNjQ0IDEwMDY0NCBi"
                + "NjhmZGUyYTA1MWQ5YWYyZmUzZmY0Yzk2YzA4OThlNWEzMjEyZTRkIGFkMjcwNWE5N2I0ZTc2OGVlMTkyNWE2Y2M1NWM2MWVmNDFl"
                + "NWQ5NjAgTQBrZWVwLnR4dAA6MDAwMDAwIDEwMDY0NCAwMDAwMDAwMDAwMDAwMDAwMDAwMDAwMDAwMDAwMDAwMDAwMDAwMDAwIDRh"
                + "ZThlZjAyMWJmNmZjZmZmNDNhMTNiZTVhYmZhNTJiYjZmYjVkYmMgQQBzdGFzaC11bnRyYWNrZWQudHh0ADowMDAwMDAgMTAwNjQ0"
                + "IDAwMDAwMDAwMDAwMDAwMDAwMDAwMDAwMDAwMDAwMDAwMDAwMDAwMDAgODM1MjY3NWQ2N2FlZDY2MjVlY2U3OWFmNDFjMjdmZGI0"
                + "ZWUyZTg2NyBBAHVkL3VudHJhY2tlZC5iaW4AMQkwCQBkb2NzL21hbnVhbC5tZABkb2NzL2hhbmRib29rLm1kADEJMAlrZWVwLnR4"
                + "dAAxCTAJc3Rhc2gtdW50cmFja2VkLnR4dAAtCS0JdWQvdW50cmFja2VkLmJpbgA="
        ) ?? Data()

    /// `commitFiles` output for the same stash's third parent (`stash@{0}^3`, the untracked part, a root commit).
    static let stashUntrackedPart =
        Data(
            base64Encoded:
                "OjAwMDAwMCAxMDA2NDQgMDAwMDAwMDAwMDAwMDAwMDAwMDAwMDAwMDAwMDAwMDAwMDAwMDAwMCA0YWU4ZWYwMjFiZjZmY2ZmZjQz"
                + "YTEzYmU1YWJmYTUyYmI2ZmI1ZGJjIEEAc3Rhc2gtdW50cmFja2VkLnR4dAA6MDAwMDAwIDEwMDY0NCAwMDAwMDAwMDAwMDAwMDAw"
                + "MDAwMDAwMDAwMDAwMDAwMDAwMDAwMDAwIDgzNTI2NzVkNjdhZWQ2NjI1ZWNlNzlhZjQxYzI3ZmRiNGVlMmU4NjcgQQB1ZC91bnRy"
                + "YWNrZWQuYmluADEJMAlzdGFzaC11bnRyYWNrZWQudHh0AC0JLQl1ZC91bnRyYWNrZWQuYmluAA=="
        ) ?? Data()
}
