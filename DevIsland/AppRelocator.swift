import AppKit
import Foundation

enum AppRelocator {
    static func checkAndPrompt() {
        // applicationDidFinishLaunching 완료 후 실행해 메인 런루프 차단 방지
        DispatchQueue.main.async {
            _checkAndPrompt()
        }
    }

    private static func _checkAndPrompt() {
        let bundleURL = Bundle.main.bundleURL
        guard let applicationsURL = FileManager.default.urls(for: .applicationDirectory, in: .localDomainMask).first else { return }
        let destinationURL = applicationsURL.appendingPathComponent(bundleURL.lastPathComponent)

        // 1. 이미 /Applications 폴더에서 실행 중인지 확인
        // hasPrefix 단순 비교는 "/Applications Backup/" 같은 경로와 오탐할 수 있어 standardized + "/" 사용
        let standardizedBundle = bundleURL.standardized.path
        let standardizedApps = applicationsURL.standardized.path
        if standardizedBundle.hasPrefix(standardizedApps + "/") || standardizedBundle == standardizedApps {
            checkAndPromptForDMGCleanup()
            return
        }

        // 2. DMG 내부에서 실행 중인지 확인 (보통 /Volumes 아래에 마운트됨)
        // 단, /Volumes/data/ 처럼 개발용 볼륨에서 실행 중인 경우는 제외
        guard bundleURL.path.hasPrefix("/Volumes/"), !bundleURL.path.hasPrefix("/Volumes/data/") else { return }

        // 3. 사용자에게 이동 권유
        let alert = NSAlert()
        alert.messageText = "응용 프로그램 폴더로 이동하시겠습니까?"
        alert.informativeText = "DevIsland를 응용 프로그램 폴더로 이동하여 계속 사용하시겠습니까?"
        alert.alertStyle = .informational
        alert.addButton(withTitle: "이동 및 다시 실행")
        alert.addButton(withTitle: "나중에")

        if alert.runModal() == .alertFirstButtonReturn {
            relocate(to: destinationURL)
        }
    }

    private static func relocate(to destinationURL: URL) {
        let bundleURL = Bundle.main.bundleURL
        let fm = FileManager.default

        guard fm.isWritableFile(atPath: destinationURL.deletingLastPathComponent().path) else {
            let alert = NSAlert()
            alert.messageText = "이동 실패"
            alert.informativeText = "응용 프로그램 폴더에 쓰기 권한이 없습니다. Finder에서 직접 이동해주세요."
            alert.runModal()
            return
        }

        do {
            // 기존 파일은 완전 삭제 대신 휴지통으로 이동 — 복사 실패 시 복구 가능
            if fm.fileExists(atPath: destinationURL.path) {
                try fm.trashItem(at: destinationURL, resultingItemURL: nil)
            }

            try fm.copyItem(at: bundleURL, to: destinationURL)

            let configuration = NSWorkspace.OpenConfiguration()
            NSWorkspace.shared.openApplication(at: destinationURL, configuration: configuration) { _, error in
                if let error = error {
                    print("새 위치에서 앱 실행 실패: \(error)")
                    return
                }
                // 새 인스턴스가 실행될 시간을 확보한 후 종료
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                    NSApplication.shared.terminate(nil)
                }
            }
        } catch {
            let alert = NSAlert()
            alert.messageText = "이동 실패"
            alert.informativeText = "앱을 이동하는 중 오류가 발생했습니다: \(error.localizedDescription)"
            alert.runModal()
        }
    }

    private static func checkAndPromptForDMGCleanup() {
        let keys: [URLResourceKey] = [.volumeNameKey, .volumeIsRemovableKey]
        guard let volumes = FileManager.default.mountedVolumeURLs(includingResourceValuesForKeys: keys, options: []) else { return }

        // hasPrefix로 매칭 — "DevIsland 0.2.3" 처럼 버전이 붙은 볼륨명도 인식
        let bundleName = Bundle.main.object(forInfoDictionaryKey: "CFBundleName") as? String ?? "DevIsland"

        for url in volumes {
            guard let values = try? url.resourceValues(forKeys: Set(keys)),
                  values.volumeName?.hasPrefix(bundleName) == true,
                  values.volumeIsRemovable == true else { continue }

            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                let alert = NSAlert()
                alert.messageText = "설치 파일을 정리하시겠습니까?"
                alert.informativeText = "설치가 완료되었습니다. 사용 중인 설치 파일(DMG)을 꺼내고 정리하시겠습니까?"
                alert.addButton(withTitle: "정리")
                alert.addButton(withTitle: "아니요")

                if alert.runModal() == .alertFirstButtonReturn {
                    ejectAndCleanup(volumeURL: url)
                }
            }
            break
        }
    }

    private static func ejectAndCleanup(volumeURL: URL) {
        do {
            try NSWorkspace.shared.unmountAndEjectDevice(at: volumeURL)
        } catch {
            let alert = NSAlert()
            alert.messageText = "꺼내기 실패"
            alert.informativeText = "설치 파일을 꺼내는 중 오류가 발생했습니다. Finder에서 직접 꺼내주세요.\n\(error.localizedDescription)"
            alert.runModal()
        }
    }
}
