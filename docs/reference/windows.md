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

실행 중에도 `설정 → WSL 배포판`에서 `Windows files only` 또는 설치된 WSL 배포판을
선택할 수 있습니다. 선택 즉시 `%APPDATA%\PokeTokenBar\wsl-distro.txt`가 갱신되고
사용량 새로고침이 예약됩니다.

설치 위치: `%LOCALAPPDATA%\Programs\PokeTokenBar`.
앱 제거는 Windows 설정의 설치된 앱 목록에서 수행합니다. 개인 상태 데이터는 자동 삭제하지 않습니다.
서명되지 않은 빌드는 Windows 경고가 표시될 수 있습니다. 보안 기능을 끄지 말고 출처와 릴리스
SHA-256을 확인하십시오. 앱 내 자동 다운로드·설치는 안전성 검증 구현 전까지 비활성 상태입니다.

## 사용량 데이터

기본적으로 현재 Windows 사용자의 `.claude/projects`, `.codex/sessions`, `.gemini/tmp`를 읽습니다.
설치 중 또는 실행 중 설정에서 WSL 배포판을 선택하면 해당 배포판에서 `$HOME`을 조회한 뒤
`\\wsl.localhost\<배포판>\<Linux home>\.claude\projects` (및 Codex/Gemini 대응 경로)를
추가로 읽습니다. 따라서 배포판마다 Linux 사용자가 다르거나 `/home` 밖에 홈을 둔 경우에도
선택한 배포판의 실제 홈을 사용합니다. 조회 시 중지된 배포판이 시작될 수 있습니다.
배포판이 삭제되었거나 조회·경로 검증에 실패한 경우에는 해당 WSL 로그를 제외하며
Windows 로그 집계는 계속합니다. 일시적인 홈 조회 실패 결과가 캐시된 경우에는 설정에서
배포판을 다시 선택하거나 앱을 다시 실행해야 재조회됩니다.
CLI를 설치만 하고 사용하지 않았거나 다른 사용자로 실행했다면 데이터가 없을 수 있습니다.

## CI 검증 범위

- Swift release 빌드 및 Windows 단위 테스트.
- Swift/Foundation/VC++ DLL을 포함한 설치 프로그램 생성.
- 개발 도구를 PATH에서 제거하고 `--version-file`로 실제 바이너리 버전 확인.
- 공백이 포함된 경로에 무인 설치하고 설치된 바이너리의 DLL 로딩 확인.
- 무인 설치가 WSL 선택 설정 파일을 생성하는지 확인. 실제 배포판 선택·Linux `$HOME` 조회는 이 테스트에 포함되지 않습니다.
- Windows 보안 테스트: 경로 검증·UTF-8/UTF-16·인자 인코딩, 프로세스 출력 제한·시간 초과·종료 코드,
  일반 파일 읽기·크기 제한, NTFS junction과 그 상위 경로 차단, 캐시 스캔 차단.
  파일 심볼릭 링크 테스트는 러너에 생성 권한이 없으면 명시적으로 skip됩니다.
- 트레이 프로세스가 5초간 유지되는지, 두 번째 실행이 중복 인스턴스를 만들지 않는지 확인.
- 무인 제거 후 실행 파일이 제거되는지 확인.

## WSL 보안 경계

- WSL 홈 경로 조회는 로그인 셸 없이 `/usr/bin/printenv HOME`을 직접 실행합니다.
  `wsl.exe` 위치는 환경변수/PATH 대신 Windows 시스템 디렉터리 API로 결정합니다.
- 홈 경로의 `.`·`..`·빈 구성요소·제어문자, Windows 예약문자·장치명·끝의 점/공백을 거부합니다.
  Linux에서 유효하더라도 Windows 경로로 모호하게 해석되는 이름은 지원하지 않습니다.
- 로그 스캔은 드라이브/UNC 공유 아래의 상위 경로와 최종 항목의 reparse point를 검사하고,
  속성 조회 실패를 거부합니다. 파서는 `OPEN_REPARSE_POINT`로 연 **파일 핸들**의 속성과 최종
  경로를 재검증하고 같은 핸들에서 읽습니다. 일반 파일이 아니거나 최종 경로를 확인할 수 없는
  파일시스템 제공자는 집계에서 제외됩니다.
- 로그 하나는 최대 256 MiB, 열었을 때 확인한 길이까지만 읽습니다. 초과 파일은 집계에서
  제외되어 사용량이 적게 표시될 수 있습니다. 전체 파일 수·파싱 CPU/메모리를 격리하는 제한은 아닙니다.
- WSL 명령 출력용 임시 파일은 더 이상 만들지 않습니다. stdout/stderr를 익명 파이프로 받아
  **합산 64 KiB·8초**로 제한합니다. 초과·실패 시 부분 결과는 사용하지 않고 Windows 조회
  프로세스를 종료한 뒤 최대 1초 동안 종료를 확인합니다.
- 자식 프로세스에는 해당 조회의 표준 입출력 핸들만 전달하며, 오류 경로의 핸들도 정리합니다.

선택한 WSL 배포판 자체, `/usr/bin/printenv`, 파일시스템 제공자와 현재 사용자 계정은 신뢰해야 합니다.
동일 사용자 또는 Linux 측 공격자가 파일을 동시에 바꾸는 모든 경쟁 조건이나 변조된 배포판을
격리하는 보안 샌드박스는 아닙니다. Windows `wsl.exe` 종료가 배포판 내부의 모든 자손 프로세스
종료를 보장하지는 않습니다. 앱은 사용자의 다른 작업을 보호하기 위해 배포판 전체를 종료하지 않습니다.

### 릴리스 전 실제 WSL 확인 (CI와 별도)

- Ubuntu와 이름에 공백이 있는 배포판에서 설정 저장 → 앱 재시작 → 실제 CLI 사용량 반영.
- 로그인 스크립트에 사용자 소유의 테스트 표식을 넣었을 때 홈 조회가 그 스크립트를 실행하지 않는지 확인.
- 홈/제공자 디렉터리/로그 파일의 링크가 집계에서 제외되고, 같은 위치의 일반 파일은 집계되는지 확인.
- 중지된 배포판 조회, 삭제된 배포판, 네트워크/UNC 제공자 오류 시 앱 생존 및 Windows 로그 집계 확인.
- 256 MiB 초과 세션이 있는 사용자는 누락 여부를 확인. 대형 로그 스트리밍 파서는 별도 후속 작업입니다.

구현 근거: [Windows 경로 규칙](https://learn.microsoft.com/en-us/windows/win32/fileio/naming-a-file),
[파일 속성 조회](https://learn.microsoft.com/en-us/windows/win32/api/fileapi/nf-fileapi-getfileattributesw),
[최종 파일 경로 확인](https://learn.microsoft.com/en-us/windows/win32/api/fileapi/nf-fileapi-getfinalpathnamebyhandlew),
[자식 핸들 상속 제한](https://learn.microsoft.com/en-us/windows/win32/api/processthreadsapi/nf-processthreadsapi-updateprocthreadattribute).

이 검증은 화면의 글꼴·배율·클릭 영역, 실제 계정의 사용량 정확성, 로그인 후 자동 시작까지
보장하지 않습니다. 사용자 PC에서 트레이 열기, 설정 변경 후 재실행, 실제 CLI 사용 후 갱신,
100%/150% 배율 확인을 별도로 수행해야 합니다. CI가 통과하기 전에는 설치 가능 완료로 간주하지 않습니다.

`scripts/test-win-installer.ps1`은 사용자 설치 등록을 변경하므로 일회용 GitHub Actions
러너에서만 실행되도록 제한되어 있습니다.
