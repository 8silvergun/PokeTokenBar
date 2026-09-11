# Windows 사용 및 검증 안내

이 포크의 Windows 제품 브랜치는 `windows-port`입니다. macOS용 `main`과 분리되어 있으며,
WindowsCore 호환 코드 기반이므로 최신 macOS 기능과 완전히 동일하지 않습니다.

## 설치

1. 이 저장소의 Releases에서 `PokeTokenBar-Setup-…-x64.exe`를 선택합니다.
2. 설치 프로그램을 실행합니다. 관리자 권한 없이 사용자별로 설치됩니다.
3. WSL 사용량 선택 화면에서 로그를 읽을 배포판을 고릅니다. WSL을 사용하지 않으면
   `Windows files only`를 선택합니다. 선택값은 `%APPDATA%\PokeTokenBar\wsl-distro.txt`에 저장됩니다.
4. 시작 메뉴에서 PokeTokenBar를 실행합니다. 작업 표시줄의 숨겨진 아이콘 영역도 확인합니다.
5. 트레이 아이콘을 눌러 사용량과 캐릭터를 확인하고, 설정에서 로그인 시 자동 시작을 선택할 수 있습니다.

설치 위치: `%LOCALAPPDATA%\Programs\PokeTokenBar`.
앱 제거는 Windows 설정의 설치된 앱 목록에서 수행합니다. 개인 상태 데이터는 자동 삭제하지 않습니다.
서명되지 않은 빌드는 Windows 경고가 표시될 수 있습니다. 보안 기능을 끄지 말고 출처와 릴리스
SHA-256을 확인하십시오. 앱 내 자동 다운로드·설치는 안전성 검증 구현 전까지 비활성 상태입니다.

## 사용량 데이터

기본적으로 현재 Windows 사용자의 `.claude/projects`, `.codex/sessions`, `.gemini/tmp`를 읽습니다.
설치 중 WSL 배포판을 선택하면 해당 배포판에서 `$HOME`을 조회한 뒤
`\\wsl.localhost\<배포판>\<Linux home>\.claude\projects` (및 Codex/Gemini 대응 경로)를
추가로 읽습니다. 따라서 배포판마다 Linux 사용자가 다르거나 `/home` 밖에 홈을 둔 경우에도
선택한 배포판의 실제 홈을 사용합니다. WSL이 중지되었거나 삭제된 경우에는 Windows 로그만
계속 집계하며 앱이 종료되지는 않습니다.
CLI를 설치만 하고 사용하지 않았거나 다른 사용자로 실행했다면 데이터가 없을 수 있습니다.

## CI 검증 범위

- Swift release 빌드 및 Windows 단위 테스트.
- Swift/Foundation/VC++ DLL을 포함한 설치 프로그램 생성.
- 개발 도구를 PATH에서 제거하고 `--version-file`로 실제 바이너리 버전 확인.
- 공백이 포함된 경로에 무인 설치하고 설치된 바이너리의 DLL 로딩 확인.
- WSL 배포판 선택값을 설치 중 저장하고, 선택한 배포판의 실제 `$HOME`을 UNC 경로로 확인.
- 트레이 프로세스가 5초간 유지되는지, 두 번째 실행이 중복 인스턴스를 만들지 않는지 확인.
- 무인 제거 후 실행 파일이 제거되는지 확인.

이 검증은 화면의 글꼴·배율·클릭 영역, 실제 계정의 사용량 정확성, 로그인 후 자동 시작까지
보장하지 않습니다. 사용자 PC에서 트레이 열기, 설정 변경 후 재실행, 실제 CLI 사용 후 갱신,
100%/150% 배율 확인을 별도로 수행해야 합니다. CI가 통과하기 전에는 설치 가능 완료로 간주하지 않습니다.

`scripts/test-win-installer.ps1`은 사용자 설치 등록을 변경하므로 일회용 GitHub Actions
러너에서만 실행되도록 제한되어 있습니다.
