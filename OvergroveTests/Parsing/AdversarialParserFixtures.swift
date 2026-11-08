import Foundation

/// Real git output (Apple Git 2.50.1) from one repository built with hostile file names, ref names and stash subjects,
/// for `AdversarialParserTests` and `ParserPropertyTests`. Captured with `core.precomposeunicode=false` so that git keeps
/// the NFD name as written; only the absolute worktree path prefix was replaced with `/tmp/dev`. APFS rejects
/// non-UTF-8 names, so the invalid UTF-8 path was put into the index with `update-index --index-info`.
///
/// A fixture that fails to decode becomes empty data, which the tests reject.
enum AdversarialParserFixtures {
    /// `status --porcelain=v2 -z --branch --show-stash --untracked-files=all --ignore-submodules=dirty`:
    /// unstaged edits to `--`, `-dash.txt`, `:(exclude)x` and `line⏎break.txt`; a staged add of `bad\xFF\xFE.txt` that is
    /// missing from the worktree (`AD`); a staged rename `old name.txt` → `new⏎name.txt`; untracked NFD `été.txt`,
    /// `quote"back\\slash.txt`, `tab⇥here.txt` and `🌳 grove.txt`.
    static let status =
        Data(
            base64Encoded:
                "IyBicmFuY2gub2lkIDc5NzIyZjI1NzBjMThhNDMxNWMzYzNkOTAzNTU3MmM2YTVhMGZjNDUAIyBicmFuY2guaGVhZCBtYWluADEg"
                + "Lk0gTi4uLiAxMDA2NDQgMTAwNjQ0IDEwMDY0NCAyOGNlNmE4YjI2YWExNzBlMWRlNjU1MzZmZThhYmUxODMyYmQzMjQyIDI4Y2U2"
                + "YThiMjZhYTE3MGUxZGU2NTUzNmZlOGFiZTE4MzJiZDMyNDIgLS0AMSAuTSBOLi4uIDEwMDY0NCAxMDA2NDQgMTAwNjQ0IDI4Y2U2"
                + "YThiMjZhYTE3MGUxZGU2NTUzNmZlOGFiZTE4MzJiZDMyNDIgMjhjZTZhOGIyNmFhMTcwZTFkZTY1NTM2ZmU4YWJlMTgzMmJkMzI0"
                + "MiAtZGFzaC50eHQAMSAuTSBOLi4uIDEwMDY0NCAxMDA2NDQgMTAwNjQ0IDI4Y2U2YThiMjZhYTE3MGUxZGU2NTUzNmZlOGFiZTE4"
                + "MzJiZDMyNDIgMjhjZTZhOGIyNmFhMTcwZTFkZTY1NTM2ZmU4YWJlMTgzMmJkMzI0MiA6KGV4Y2x1ZGUpeAAxIEFEIE4uLi4gMDAw"
                + "MDAwIDEwMDY0NCAwMDAwMDAgMDAwMDAwMDAwMDAwMDAwMDAwMDAwMDAwMDAwMDAwMDAwMDAwMDAwMCA2MTc4MDc5ODIyOGQxN2Fm"
                + "MmQzNGZjZTRjZmJkZjM1NTU2ODMyNDcyIGJhZP/+LnR4dAAxIC5NIE4uLi4gMTAwNjQ0IDEwMDY0NCAxMDA2NDQgMjhjZTZhOGIy"
                + "NmFhMTcwZTFkZTY1NTM2ZmU4YWJlMTgzMmJkMzI0MiAyOGNlNmE4YjI2YWExNzBlMWRlNjU1MzZmZThhYmUxODMyYmQzMjQyIGxp"
                + "bmUKYnJlYWsudHh0ADIgUi4gTi4uLiAxMDA2NDQgMTAwNjQ0IDEwMDY0NCAzMzY3YWZkYmJmOTFlNjM4ZWZlOTgzNjE2Mzc3YzYw"
                + "NDc3Y2M2NjEyIDMzNjdhZmRiYmY5MWU2MzhlZmU5ODM2MTYzNzdjNjA0NzdjYzY2MTIgUjEwMCBuZXcKbmFtZS50eHQAb2xkIG5h"
                + "bWUudHh0AD8gZcyBdGXMgS50eHQAPyBxdW90ZSJiYWNrXHNsYXNoLnR4dAA/IHRhYgloZXJlLnR4dAA/IPCfjLMgZ3JvdmUudHh0"
                + "AA=="
        ) ?? Data()

    /// `worktree list --porcelain -z`: the main worktree on `main`, a detached `-dash`, `line⏎break` on
    /// `feat/58-x`, and a detached `my repo` locked with the reason `on usb⏎drive`. Paths start with `/tmp/dev/`.
    static let worktree =
        Data(
            base64Encoded:
                "d29ya3RyZWUgL3RtcC9kZXYvcmVwbwBIRUFEIDc5NzIyZjI1NzBjMThhNDMxNWMzYzNkOTAzNTU3MmM2YTVhMGZjNDUAYnJhbmNo"
                + "IHJlZnMvaGVhZHMvbWFpbgAAd29ya3RyZWUgL3RtcC9kZXYvd3QvLWRhc2gASEVBRCA3OTcyMmYyNTcwYzE4YTQzMTVjM2MzZDkw"
                + "MzU1NzJjNmE1YTBmYzQ1AGRldGFjaGVkAAB3b3JrdHJlZSAvdG1wL2Rldi93dC9saW5lCmJyZWFrAEhFQUQgNzk3MjJmMjU3MGMx"
                + "OGE0MzE1YzNjM2Q5MDM1NTcyYzZhNWEwZmM0NQBicmFuY2ggcmVmcy9oZWFkcy9mZWF0LzU4LXgAAHdvcmt0cmVlIC90bXAvZGV2"
                + "L3d0L215IHJlcG8ASEVBRCA3OTcyMmYyNTcwYzE4YTQzMTVjM2MzZDkwMzU1NzJjNmE1YTBmYzQ1AGRldGFjaGVkAGxvY2tlZCBv"
                + "biB1c2IKZHJpdmUAAA=="
        ) ?? Data()

    /// `log -g -z --format=%gd%x00%H%x00%gs%x00%ct%x00%P refs/stash`: `On main: 한글 🌳 line` and `On main: exp: try -dash "q"`.
    static let stash =
        Data(
            base64Encoded:
                "c3Rhc2hAezB9AGZkZmYwYmNmOTc1ZjliMzlhZWJmZGQ3NTcyNDE3OTlhMDVhYzI5YTEAT24gbWFpbjog7ZWc6riAIPCfjLMgbGlu"
                + "ZQAxNzkzODUzNjUyAGJjZjNmMjRiNDVjODQ2NWMzOTE2MjBkZmQ3YTc1ZmU4ODlkYmI1Y2EgZjBmNGNlZTBmOTA4NTExYTg4M2Yx"
                + "ZjliZTc0MjJmYmJiNGJiZjc5MwBzdGFzaEB7MX0ANzJmN2I3MGIwNmNjMDE2NjAzY2EwNDhiZTFjZGM4NmM0YzU1ODI4YQBPbiBt"
                + "YWluOiBleHA6IHRyeSAtZGFzaCAicSIAMTc5Mzg1MzY1MgBiY2YzZjI0YjQ1Yzg0NjVjMzkxNjIwZGZkN2E3NWZlODg5ZGJiNWNh"
                + "IGYwZjRjZWUwZjkwODUxMWE4ODNmMWY5YmU3NDIyZmJiYjRiYmY3OTMA"
        ) ?? Data()

    /// `diff-tree -r -z --raw --numstat -M HEAD~1 HEAD`: binary add `-bin.dat`, edits to `:(exclude)x` and
    /// `line⏎break.txt`, an add of `bad\xFF\xFE.txt`, and a pure rename `old name.txt` → `new⏎name.txt`.
    static let numstat =
        Data(
            base64Encoded:
                "OjAwMDAwMCAxMDA2NDQgMDAwMDAwMDAwMDAwMDAwMDAwMDAwMDAwMDAwMDAwMDAwMDAwMDAwMCA4ODc2OGVmZGY3N2VjNzhjOWE5"
                + "OTVmOTQ4ODE3OTNiZTZhNDE3NTJiIEEALWJpbi5kYXQAOjEwMDY0NCAxMDA2NDQgMjhjZTZhOGIyNmFhMTcwZTFkZTY1NTM2ZmU4"
                + "YWJlMTgzMmJkMzI0MiAwNjc1MTMyYWQyODU3MzNhNmEzMjU5Y2FiZDMyYmQxZDNiNjRlY2UwIE0AOihleGNsdWRlKXgAOjAwMDAw"
                + "MCAxMDA2NDQgMDAwMDAwMDAwMDAwMDAwMDAwMDAwMDAwMDAwMDAwMDAwMDAwMDAwMCA2MTc4MDc5ODIyOGQxN2FmMmQzNGZjZTRj"
                + "ZmJkZjM1NTU2ODMyNDcyIEEAYmFk//4udHh0ADoxMDA2NDQgMTAwNjQ0IDI4Y2U2YThiMjZhYTE3MGUxZGU2NTUzNmZlOGFiZTE4"
                + "MzJiZDMyNDIgMDY3NTEzMmFkMjg1NzMzYTZhMzI1OWNhYmQzMmJkMWQzYjY0ZWNlMCBNAGxpbmUKYnJlYWsudHh0ADoxMDA2NDQg"
                + "MTAwNjQ0IDMzNjdhZmRiYmY5MWU2MzhlZmU5ODM2MTYzNzdjNjA0NzdjYzY2MTIgMzM2N2FmZGJiZjkxZTYzOGVmZTk4MzYxNjM3"
                + "N2M2MDQ3N2NjNjYxMiBSMTAwAG9sZCBuYW1lLnR4dABuZXcKbmFtZS50eHQALQktCS1iaW4uZGF0ADIJMAk6KGV4Y2x1ZGUpeAAx"
                + "CTAJYmFk//4udHh0ADIJMAlsaW5lCmJyZWFrLnR4dAAwCTAJAG9sZCBuYW1lLnR4dABuZXcKbmFtZS50eHQA"
        ) ?? Data()

    /// `stash show --include-untracked --numstat -z stash@{1}`: `-dash.txt`, `bad\xFF\xFE.txt` and the rename.
    static let stashShow =
        Data(
            base64Encoded:
                "MQkwCS1kYXNoLnR4dAAxCTAJYmFk//4udHh0ADAJMAkAb2xkIG5hbWUudHh0AG5ldwpuYW1lLnR4dAA="
        ) ?? Data()

    /// `config --list --show-scope -z --includes` of the same repository (no global or system config).
    static let config =
        Data(
            base64Encoded:
                "bG9jYWwAY29yZS5yZXBvc2l0b3J5Zm9ybWF0dmVyc2lvbgowAGxvY2FsAGNvcmUuZmlsZW1vZGUKdHJ1ZQBsb2NhbABjb3JlLmJh"
                + "cmUKZmFsc2UAbG9jYWwAY29yZS5sb2dhbGxyZWZ1cGRhdGVzCnRydWUAbG9jYWwAY29yZS5pZ25vcmVjYXNlCnRydWUAbG9jYWwA"
                + "Y29yZS5wcmVjb21wb3NldW5pY29kZQpmYWxzZQA="
        ) ?? Data()

    /// `for-each-ref` in the `ReadOnlyGitCommand.refs` format (`LC_ALL=C`) after adding branches `(detached)`,
    /// `(initial)`, `한글/🌳-name`, `refs/heads/-odd` and `refs/tags/-lead` (via `update-ref`), an annotated tag `v1-🌳`,
    /// `main` one commit ahead of `origin/main`, `feat/58-x` tracking a missing branch (`gone`), and `origin/HEAD`.
    /// Captured before `%(upstream:remotename)` and `%(upstream:remoteref)` joined the format (#115); those two fields are
    /// appended as git prints them for this repository (`origin` and `refs/heads/<name>` for `main` and `feat/58-x`).
    static let refs =
        Data(
            base64Encoded:
                "cmVmcy9oZWFkcy8oZGV0YWNoZWQpADRhYjQ0YmQ4MWEyZmQ4ODhlN2FlODY2MGZhMzU2YzI0YWM4NGIxZmMAAAAgADE3OTM4NTM2"
                + "NTIAAAAACnJlZnMvaGVhZHMvKGluaXRpYWwpADRhYjQ0YmQ4MWEyZmQ4ODhlN2FlODY2MGZhMzU2YzI0YWM4NGIxZmMAAAAgADE3"
                + "OTM4NTM2NTIAAAAACnJlZnMvaGVhZHMvLW9kZAA0YWI0NGJkODFhMmZkODg4ZTdhZTg2NjBmYTM1NmMyNGFjODRiMWZjAAAAIAAx"
                + "NzkzODUzNjUyAAAAAApyZWZzL2hlYWRzL2ZlYXQvNTgteAA3OTcyMmYyNTcwYzE4YTQzMTVjM2MzZDkwMzU1NzJjNmE1YTBmYzQ1"
                + "AAByZWZzL3JlbW90ZXMvb3JpZ2luL21pc3NpbmcAIAAxNzkzODUzNjUyAABnb25lAG9yaWdpbgByZWZzL2hlYWRzL21pc3NpbmcK"
                + "cmVmcy9oZWFkcy9tYWluADRhYjQ0YmQ4MWEyZmQ4ODhlN2FlODY2MGZhMzU2YzI0YWM4NGIxZmMAAHJlZnMvcmVtb3Rlcy9vcmln"
                + "aW4vbWFpbgAqADE3OTM4NTM2NTIAAGFoZWFkIDEAb3JpZ2luAHJlZnMvaGVhZHMvbWFpbgpyZWZzL2hlYWRzL+2VnOq4gC/wn4yz"
                + "LW5hbWUANGFiNDRiZDgxYTJmZDg4OGU3YWU4NjYwZmEzNTZjMjRhYzg0YjFmYwAAACAAMTc5Mzg1MzY1MgAAAAAKcmVmcy9yZW1v"
                + "dGVzL29yaWdpbi9IRUFEADc5NzIyZjI1NzBjMThhNDMxNWMzYzNkOTAzNTU3MmM2YTVhMGZjNDUAAAAgADE3OTM4NTM2NTIAcmVm"
                + "cy9yZW1vdGVzL29yaWdpbi9tYWluAAAACnJlZnMvcmVtb3Rlcy9vcmlnaW4vbWFpbgA3OTcyMmYyNTcwYzE4YTQzMTVjM2MzZDkw"
                + "MzU1NzJjNmE1YTBmYzQ1AAAAIAAxNzkzODUzNjUyAAAAAApyZWZzL3RhZ3MvLWxlYWQANGFiNDRiZDgxYTJmZDg4OGU3YWU4NjYw"
                + "ZmEzNTZjMjRhYzg0YjFmYwAAACAAMTc5Mzg1MzY1MgAAAAAKcmVmcy90YWdzL3YxLfCfjLMAM2JhYTc2NDU0ZDM3MzM2YzQzOTFl"
                + "MWE0NDM2YjY4NDVkMmJkNDMyOQA0YWI0NGJkODFhMmZkODg4ZTdhZTg2NjBmYTM1NmMyNGFjODRiMWZjAAAgAAAAAAAK"
        ) ?? Data()

    /// `rev-list --left-right --count --end-of-options refs/remotes/origin/main...refs/heads/main`.
    static let revList = Data("0\t1\n".utf8)
}
