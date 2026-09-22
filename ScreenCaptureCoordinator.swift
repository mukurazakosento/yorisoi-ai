import Foundation

final class ScreenCaptureCoordinator: NSObject {

    var onOCR: ((String) -> Void)?
    var onStatus: ((String) -> Void)?

    override init() {
        super.init()
        onStatus?("画面取得：iOS 26版では停止中")
    }

    func startFullDisplayCapture() async throws {
        onStatus?("画面取得：このiOS版では利用できません")
    }

    func pauseAnalysis() {
        onStatus?("画面解析：一時停止")
    }

    func resumeAnalysis() {
        onStatus?("画面解析：再開")
    }

    func stop() {
        onStatus?("画面取得：停止中")
    }
}
