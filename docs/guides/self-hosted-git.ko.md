# 자체 호스팅·사내 Git 서버

> 상태: Accepted · 관련: #152, #161, #150, #153, #117 · English: [self-hosted-git.md](self-hosted-git.md)

Overgrove는 호스트를 가리지 않고 Git 저장소를 읽는다. Forgejo, Gitea, GitLab, Bitbucket, GitHub Enterprise, 사내 서버 모두 된다. 네트워크를 쓰는 동작은 **Fetch** 하나뿐이고, Fetch는 사용자가 이미 Git에 설정해 둔 인증을 쓴다. Overgrove는 비밀번호나 토큰을 묻지 않고 저장하지도 않는다.

Overgrove는 신뢰할 수 없는 저장소도 연다. 그래서 Git을 보안을 강화한 방식으로 실행하고, 터미널에서는 되던 설정 몇 가지가 한 단계를 더 요구한다. 이 문서는 그 단계를 설명한다. 영어판과 내용이 같다.

## Overgrove가 Fetch를 실행하는 방식

| 항목 | Overgrove가 하는 일 | 사용자에게 의미하는 것 |
|---|---|---|
| 프롬프트 | `GIT_TERMINAL_PROMPT=0`, 빈 `GIT_ASKPASS`·`SSH_ASKPASS` | 비밀번호, 암호문, 호스트 키를 묻는 창이 뜨지 않는다. 자격 증명이 미리 저장되어 있어야 한다 |
| HTTPS 자격 증명 | **system·global** Git 설정(`~/.config/git/config`, 그 설정이 include한 파일, Apple Git 내장 설정 포함)의 credential helper(예: `osxkeychain`, Git Credential Manager)를 쓴다. 저장소 자체의 `credential.helper`는 무시한다 | 터미널에서 토큰을 한 번 저장한다(아래) |
| SSH | `ssh -o BatchMode=yes`를 실행한다. **system·global** `core.sshCommand`가 있으면 그것을 쓴다. 저장소 자체의 `core.sshCommand`는 무시한다. `~/.ssh/config`와 SSH agent(`SSH_AUTH_SOCK`)는 평소대로 쓰인다 | 키가 agent나 macOS 키체인에 있어야 하고, 호스트가 `known_hosts`에 미리 있어야 한다 |
| 환경 변수 | 짧은 허용 목록만 Git에 전달한다(`HOME`, `USER`, `LOGNAME`, `TMPDIR`, `SSH_AUTH_SOCK`과 고정값). 셸의 다른 변수는 전달하지 않는다 | `HTTPS_PROXY`, `GIT_SSH_COMMAND` 같은 셸 변수는 효과가 없다. 설정은 global Git 설정에 둔다 |
| 전송 | Git 내장 전송만 쓴다: `https`, `http`, `ssh`, `git`, `file` | `ftp://`·`ftps://` 원격과 커스텀 원격 helper는 fetch할 수 없다([한계](#한계)) |
| TLS | 저장소가 인증서 검사를 끌 수 없다. 저장소 자체 설정에 CA나 클라이언트 인증서가 있으면 그 저장소의 Fetch를 끈다 | CA와 클라이언트 인증서는 global 설정에 둔다 |
| 시간 제한 | fetch는 120초가 지나면 멈춘다 | 아주 큰 첫 fetch는 신뢰하는 저장소라면 터미널에서 한 번 하는 편이 낫다 |

워크트리, 이력, diff 보기는 네트워크를 쓰지 않으므로 위 내용과 관계없다.

> **터미널은 신뢰하는 저장소에서만 쓴다.** 터미널의 Git은 보안 강화가 적용되지 않는다. 저장소의 hook, 저장소 자체의 `core.sshCommand`, credential helper, 프록시, pager를 실행한다. Overgrove의 fetch 실패 안내도 저장소 설정 보고가 깨끗할 때만 Git 명령을 제시한다. 아래 단계는 신뢰하는 저장소에서 따른다.

## HTTPS와 토큰

Overgrove는 credential helper가 저장한 토큰을 쓴다. 한 번 저장한다.

1. helper가 설정되어 있는지 확인한다. 저장소 설정이 끼어들지 않게 저장소 밖(예: 홈 폴더)에서 실행한다: `git --no-pager config --show-origin --get-all credential.helper`
   - Apple의 Git(Xcode나 Command Line Tools)은 system 설정에 `osxkeychain`을 둔다.
   - Git Credential Manager(`brew install --cask git-credential-manager`)는 global 설정에 자신을 추가한다.
2. 저장소 밖에서 터미널로 Git이 토큰을 한 번 묻게 한다: `git ls-remote https://git.example.com/team/app.git`(원격 URL로 바꾼다). Git이 물으면 사용자 이름과 토큰(개인 액세스 토큰이나 앱 비밀번호)을 입력한다. helper가 키체인에 저장한다. 신뢰하는 저장소에서 `git fetch`를 해도 된다.
3. Overgrove에서 Fetch한다.

한 호스트에서 계정을 여러 개 쓰면 **global** 설정에 URL별 helper나 사용자 이름을 둔다. 예: `git config --global credential.https://git.example.com.username alice`

토큰이 만료되면 Fetch가 "Authentication failed"로 실패한다. 2단계를 다시 해서 새 토큰을 저장한다.

## SSH

1. **호스트 키를 한 번 등록한다.** Overgrove는 "Are you sure you want to continue connecting?"에 답할 수 없다.
   - 터미널에서 한 번 접속하고(`ssh -T git@git.example.com`), 서버 관리자에게 받은 지문과 비교한 뒤 수락한다.
   - 또는 키를 받아서 신뢰하기 **전에** 비교한 뒤 추가한다.

     ```sh
     ssh-keyscan -p 22 git.example.com > /tmp/host-key
     ssh-keygen -lf /tmp/host-key          # 관리자가 공개한 지문과 비교
     cat /tmp/host-key >> ~/.ssh/known_hosts   # 일치할 때만
     ```
2. **암호문을 묻지 않게 키를 올린다.** `ssh-add --apple-use-keychain ~/.ssh/id_ed25519`를 실행한다. 자동으로 올리려면 `~/.ssh/config`에 다음을 둔다.

   ```
   Host git.example.com
     UseKeychain yes
     AddKeysToAgent yes
     IdentityFile ~/.ssh/id_ed25519
   ```

3. **다른 포트, 점프 호스트, 호스트별 키**는 `~/.ssh/config`(`Port`, `ProxyJump`, `IdentityFile`)에 둔다. Overgrove의 ssh가 읽는다.
4. **ssh 명령을 바꾸려면** global 설정에 둔다: `git config --global core.sshCommand "ssh -o BatchMode=yes -i ~/.ssh/work_key"`. `-o BatchMode=yes`를 빼지 않는다. 빼면 아무도 답할 수 없는 프롬프트를 기다리다가 120초 제한에 걸려 멈출 수 있다.

## 사설 인증 기관(CA)

서버 인증서를 회사 CA가 서명했다면 **global** 설정에 CA 묶음을 지정한다.

```sh
git config --global http.sslCAInfo /path/to/company-ca.pem
# 그 서버에만:
git config --global http.https://git.example.com/.sslCAInfo /path/to/company-ca.pem
```

클라이언트 인증서도 같은 방식이다(`http.sslCert`, `http.sslKey`, global 또는 URL별).

**저장소 자체** 설정에 `http.sslCAInfo`, `http.sslCAPath`, `http.sslCert`, `http.sslKey`가 있으면 Overgrove는 그 저장소의 Fetch를 끄고 이유를 보여 준다. 그렇지 않으면 저장소가 고른 인증서를 믿고 자격 증명을 보내게 될 수 있다. 설정을 global로 옮기고 저장소에서 지운다(`git config --local --unset http.sslCAInfo`). 저장소는 `http.sslVerify=false`도 걸 수 없다. Overgrove는 검증을 켠 채로 fetch한다.

## 프록시

Overgrove는 셸의 `HTTPS_PROXY`, `HTTP_PROXY`, `ALL_PROXY`, `NO_PROXY`를 Git에 전달하지 않고, Git은 macOS 네트워크 프록시 설정을 읽지 않는다. 프록시는 **global** Git 설정에 둔다.

```sh
git config --global http.proxy http://proxy.example.com:8080
# 한 서버에만:
git config --global http.https://git.example.com/.proxy http://proxy.example.com:8080
```

저장소 자체 설정의 프록시는 global 값으로(없으면 프록시 없음으로) 바뀐다. 저장소가 고른 프록시로 자격 증명이 나가지 않게 하기 위해서다.

SSH 원격은 `~/.ssh/config`의 `ProxyCommand`나 `ProxyJump`를 쓴다. global `core.gitProxy`(`git://` 원격용)는 쓰이지 않는다.

셸 프록시 변수를 전달할지는 아직 결정 중이다([#153](https://github.com/kkdy21/overgrove/issues/153)).

## 원격 URL 예시

내장 전송을 쓰는 한 Git이 받는 형식은 모두 된다.

| 서버 | HTTPS | SSH |
|---|---|---|
| Forgejo / Gitea | `https://git.example.com/team/app.git` | `ssh://git@git.example.com:2222/team/app.git` |
| GitLab (self-managed) | `https://gitlab.example.com/group/subgroup/app.git` | `git@gitlab.example.com:group/subgroup/app.git` |
| Bitbucket Data Center | `https://bitbucket.example.com/scm/proj/app.git` | `ssh://git@bitbucket.example.com:7999/proj/app.git` |
| GitHub Enterprise Server | `https://github.example.com/org/app.git` | `git@github.example.com:org/app.git` |

## Fetch가 실패할 때

Overgrove는 상태바(`Fetch failed — Details`)에 이유를 보여 준다. Details에는 다음 중 하나가 나온다.

| Overgrove의 문구 | 흔한 원인 | 할 일 |
|---|---|---|
| Authentication failed for … | 저장된 자격 증명이 없거나 토큰이 만료됨 | [HTTPS와 토큰](#https와-토큰) |
| The SSH key was rejected for … | 키가 agent에 없거나 서버가 키를 모름 | [SSH](#ssh) 2단계. `ssh-add -l`로 확인 |
| The SSH host key … is not trusted yet / has changed | 호스트가 `known_hosts`에 없거나 키가 바뀜 | [SSH](#ssh) 1단계. 키가 예상 없이 **바뀌었으면** 수락하기 전에 관리자에게 확인 |
| Access to … was denied | 그 계정이 저장소를 읽을 수 없음 | 권한 확인, 또는 그 호스트의 사용자 이름 설정 |
| Could not reach … | 네트워크, VPN, 프록시 | [프록시](#프록시). VPN 확인 |
| Fetch timed out after … s | 느린 연결이나 아주 큰 저장소 | 신뢰하는 저장소에서 터미널로 한 번 fetch |
| The repository for … was not found | 잘못된 URL, 또는 볼 수 없는 비공개 저장소 | 신뢰하는 저장소에서 `git --no-pager remote -v`로 URL 확인 |
| Overgrove does not fetch … | `ftp://`, `ftps://`, 커스텀 원격 helper | [한계](#한계) |
| Fetching … is turned off for this repository | 저장소 자체 설정에 CA·클라이언트 인증서 등이 있음, 또는 Git 2.45.1 미만의 partial clone | [사설 인증 기관(CA)](#사설-인증-기관ca), [한계](#한계) |

## 한계

- **내장 전송만 쓴다.** 커스텀 원격 helper가 필요한 원격(`codecommit::…`, `gcrypt::…`, `hg::…`, 또는 저장소가 그런 URL로 바꿔치기한 원격)은 v0.1에서 fetch할 수 없다. 허용하면 저장소가 helper 프로그램과 인자를 고를 수 있기 때문이다. 나중에 허용하더라도 저장소 설정이 아니라 사용자가 고르는 앱 설정으로만 연다.
- **`ftp://`·`ftps://`**는 Git 내장이지만 거의 쓰이지 않아 허용 목록에 없다.
- **`core.gitProxy`를 거치는 `git://`**는 지원하지 않는다.
- **이슈**(사이드바 ISSUES와 이슈 패널)는 v0.1에서 github.com만 지원한다. GitHub Enterprise 호스트는 계획되어 있다([#117](https://github.com/kkdy21/overgrove/issues/117)). GitHub Enterprise 서버에서의 Fetch는 다른 Git 서버와 똑같이 된다.
- **partial clone**(`--filter`)은 Git 2.45.1 이상에서만 fetch할 수 있다. 아직 받지 않은 객체가 필요한 화면은 그 객체를 받는 대신 오류를 보여 준다.

규칙의 근거는 [보안 검토](../design/security-review.md)(T5, T6, T11, T12)에 있다.
