import AppKit
import Foundation

enum AppRelocator {
    static func checkAndPrompt() {
        let bundleURL = Bundle.main.bundleURL
        let applicationsURL = FileManager.default.urls(for: .applicationDirectory, in: .localDomainMask).first!
        let destinationURL = applicationsURL.appendingPathComponent(bundleURL.lastPathComponent)
        
        // 1. 이미 /Applications 폴더에서 실행 중인지 확인
        if bundleURL.path.hasPrefix(applicationsURL.path) {
            // 설치가 완료된 상태라면 설치 파일(DMG) 정리 제안
            checkAndPromptForDMGCleanup()
            return
        }
        
        // 2. DMG 내부에서 실행 중인지 확인 (보통 /Volumes 아래에 마운트됨)
        guard bundleURL.path.hasPrefix("/Volumes/") else { return }
        
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
        
        do {
            // 기존 파일이 있으면 삭제
            if fm.fileExists(atPath: destinationURL.path) {
                try fm.removeItem(at: destinationURL)
            }
            
            // 앱 복사
            try fm.copyItem(at: bundleURL, to: destinationURL)
            
            // 새 위치에서 앱 실행
            let configuration = NSWorkspace.OpenConfiguration()
            NSWorkspace.shared.openApplication(at: destinationURL, configuration: configuration) { _, error in
                if let error = error {
                    print("새 위치에서 앱 실행 실패: \(error)")
                }
                // 현재 앱 종료
                DispatchQueue.main.async {
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
        // 마운트된 볼륨 중 'DevIsland'라는 이름의 디스크 이미지가 있는지 확인
        let keys: [URLResourceKey] = [.volumeNameKey, .volumeIsRemovableKey]
        guard let volumes = FileManager.default.mountedVolumeURLs(includingResourceValuesForKeys: keys, options: []) else { return }
        
        for url in volumes {
            guard let values = try? url.resourceValues(forKeys: Set(keys)),
                  values.volumeName == "DevIsland",
                  values.volumeIsRemovable == true else { continue }
            
            // 찾았을 경우 정리 제안
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
        // 볼륨 꺼내기
        try? NSWorkspace.shared.unmountAndEjectDevice(at: volumeURL)
    }
}
