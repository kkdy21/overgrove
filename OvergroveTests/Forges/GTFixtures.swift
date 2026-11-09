import Foundation

/// gt 1.1.0 (gitea/cli) output (#449, ADR-0026), captured on 2026-11-08 from the official release binary (checksum
/// verified) without logging in to any account.
enum GTFixtures {
    /// `gt issue list --host … --repo acme/widgets --state open --kind issues --limit 200 --no-input --json
    /// number,title,state,labels,assignees,updated_at,url`. gt cannot list issues without an account, so it ran with a
    /// placeholder `GITEA_TOKEN` against a local stand-in for the Gitea API that served two issue objects; the JSON
    /// below is gt's own output (field selection, label objects, assignee logins, `url` from `html_url`). The first
    /// title carries U+202E (right-to-left override), escaped at display.
    static let issues =
        ##"[{"assignees":["alice","bob"],"labels":[{"color":"ee0701","description":"d","exclusive":false,"id":1,"is_archived":false,"name":"bug"},{"color":"00aabb","description":"","exclusive":true,"id":2,"is_archived":false,"name":"area/ui"}],"number":7,"state":"open","title":"Crash when ‮opening","updated_at":"2026-11-07T09:30:00+09:00","url":"https://git.example.com/acme/widgets/issues/7"},{"assignees":[],"labels":[],"number":8,"state":"open","title":"No labels","updated_at":"2026-11-06T00:00:00Z","url":"https://git.example.com/acme/widgets/issues/8"}]"##

    /// `gt auth status --json host,user,credential_available` with no account (exit code 0).
    static let authNone = "[]"

    /// The same command with a placeholder `GITEA_TOKEN` and `GITEA_CLI_HOST=http://127.0.0.1:18449` (captured): an
    /// http instance, which Overgrove does not trust.
    static let authHTTPInstance =
        ##"[{"credential_available":true,"host":"http://127.0.0.1:18449","user":""}]"##

    /// The captured shape with https instances (gt prints the host lowercase, keeps the base path, and drops a
    /// trailing `/`, measured): one usable account, one without credentials, and one with a base path.
    static let authAccounts =
        ##"[{"credential_available":true,"host":"https://git.example.com","user":"alice"},{"credential_available":false,"host":"https://other.example.com","user":"bob"},{"credential_available":true,"host":"https://code.example.org:8443/gitea","user":"alice"}]"##
}
