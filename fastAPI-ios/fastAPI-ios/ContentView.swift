//
//  ContentView.swift
//  fastAPI-ios
//
//  Created by Buseong Kim on 12/8/25.
//

import SwiftUI
import PylibKit_iOS
import Combine

struct ContentView: View {
    @StateObject private var viewModel = FastAPIServerViewModel()

    var body: some View {
        VStack {
            Text("FastAPI (PylibKit)")
                .font(.title2)
                .padding(.bottom, 8)

            Text(viewModel.statusText)
                .font(.subheadline)
                .foregroundStyle(.secondary)

            Text(viewModel.endpointText)
                .font(.footnote)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)

            HStack {
                Button {
                    viewModel.startServer()
                } label: {
                    Text("Start")
                        .frame(maxWidth: .infinity)
                }
                .disabled(!viewModel.canStart)
                .buttonStyle(.borderedProminent)

                Button {
                    viewModel.stopServer()
                } label: {
                    Text("Stop")
                        .frame(maxWidth: .infinity)
                }
                .disabled(!viewModel.canStop)
                .buttonStyle(.bordered)
            }
            .padding(.vertical, 8)

            ScrollView {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(viewModel.logs.indices, id: \.self) { idx in
                        Text(viewModel.logs[idx])
                            .font(.footnote)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .background(Color(uiColor: .secondarySystemBackground))
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .padding(.top, 8)

            Spacer()
        }
        .padding(.horizontal, 16)
        .padding(.top, 24)
    }
}

#Preview {
    ContentView()
}

@MainActor
final class FastAPIServerViewModel: ObservableObject {
    enum Status {
        case idle
        case starting
        case running
        case stopping
        case failed(String)
    }

    @Published var status: Status = .idle
    @Published var logs: [String] = []

    private var executor: PythonExecutor?
    private var loop: AsyncioLoop?
    private var app: Fastapi.Applications.FastapiInstance?
    private var server: Uvicorn.ServerInstance?
    private var serverTask: Task<Void, Never>?

    private let host = "0.0.0.0"
    private let port: Int = 8000
    var endpointText: String {
        "Endpoint: http://\(host):\(port)/ping"
    }

    var statusText: String {
        switch status {
        case .idle:
            return "Idle"
        case .starting:
            return "Starting (preparing Python)…"
        case .running:
            return "Running (uvicorn \(host):\(port))"
        case .stopping:
            return "Stopping…"
        case .failed(let message):
            return "Failed: \(message)"
        }
    }

    var canStart: Bool {
        switch status {
        case .idle, .failed:
            return true
        default:
            return false
        }
    }

    var canStop: Bool {
        switch status {
        case .running, .starting:
            return true
        default:
            return false
        }
    }

    func startServer() {
        guard canStart else { return }
        status = .starting
        appendLog("Python executor 준비 중…")

        Task {
            // 매번 새로운 executor를 만들어 누적된 Python state로 인한 재시작 실패를 방지.
            let executor = PythonExecutor()
            do {
                await executor.installPythonLogForwarders(logLevel: .debug) // pipe Python/uvicorn logs back to Swift logger
                let loop = await executor.createAsyncioLoop()
                appendLog("Python 환경 초기화 완료 (asyncio loop 생성).")

                // FastAPI 기본 generate_unique_id 함수를 Python에서 로드해 전달
                let utils = await Fastapi.Utils.UtilsService.create(executor: executor)
                let genIdFunc = try await utils.callable.generate_unique_id()

                let app = try await Fastapi.Applications.FastapiInstance.create(
                    executor: executor,
                    title: "iPhone FastAPI",
                    version: "1.0.0",
                    openapi_url: "/openapi.json",
                    docs_url: "/docs",
                    redoc_url: "/redoc",
                    generate_unique_id_function: genIdFunc
                )
                
                
                let endpoint = await executor.buildCallable { (requests: Starlette.Requests.RequestInstance) -> [String: String] in
                    ["message": "pong"]
                }
                try await app.add_api_route(
                    path: "/ping",
                    endpoint: endpoint,
                    methods: ["GET"],
                    generate_unique_id_function: genIdFunc
                )
                appendLog("라우트 등록: GET /ping -> {\"message\": \"pong\"} (Swift buildCallable)")

                // uvicorn 서버 설정 및 실행
                let config = try await Uvicorn.Config.ConfigInstance.create(
                    executor: executor,
                    app: app,
                    host: host,
                    port: port,
                    loop: "asyncio",
                    log_level: "info",
                    access_log: true,
                    root_path: ""
                )
                appendLog("config.load() 시작")
                try await config.load() // ensure uvicorn Config is loaded before starting server
                appendLog("config.load() 완료")

                appendLog("ServerClient.create 시작")
                let server = try await Uvicorn.ServerInstance.create(executor: executor, config: config)
                appendLog("ServerClient.create 완료")
                appendLog("uvicorn 설정 완료 (\(host):\(port))")

                let serverTask = Task.detached { [weak self] in
                    do {
                        try await server.serve()
                    } catch is CancellationError {
                        // Expected when stopServer() cancels the task after shutdown.
                    } catch {
                        await MainActor.run {
                            self?.appendLog("uvicorn serve error: \(error.localizedDescription)")
                            self?.status = .failed(error.localizedDescription)
                        }
                    }
                }

                self.executor = executor
                self.loop = loop
                self.app = app
                self.server = server
                self.serverTask = serverTask
                status = .running
                appendLog("서버 실행 중 (http://\(host):\(port))")
            } catch {
                status = .failed(error.localizedDescription)
                appendLog("에러 발생: \(error.localizedDescription)")
            }
        }
    }

    func stopServer() {
        guard canStop else { return }
        status = .stopping
        appendLog("서버 종료 시그널 전송 중…")

        let serverRef = server
        let serverTaskRef = serverTask

        // Clear references immediately so 다음 시작 시 새 executor/loop 사용
        server = nil
        serverTask = nil
        app = nil
        executor = nil
        loop = nil

        Task {
            if let serverRef {
                appendLog("server.handle_exit(SIGTERM) 호출 (최대 2초 대기)")
                do {
                    try await withThrowingTaskGroup(of: Void.self) { group in
                        group.addTask {
                            try await serverRef.handle_exit(sig: "SIGTERM", frame: NSNull())
                        }
                        group.addTask {
                            try await Task.sleep(nanoseconds: 2_000_000_000)
                            throw CancellationError()
                        }
                        _ = try await group.next()
                        group.cancelAll()
                    }
                    appendLog("handle_exit 완료")
                } catch is CancellationError {
                    appendLog("handle_exit 타임아웃/취소 -> shutdown 강제 진행")
                } catch {
                    appendLog("handle_exit 예외: \(error.localizedDescription)")
                }

                appendLog("server.shutdown() 대기 시작 (최대 3초)")
                do {
                    try await withThrowingTaskGroup(of: Void.self) { group in
                        group.addTask {
                            try await serverRef.shutdown()
                        }
                        group.addTask {
                            try await Task.sleep(nanoseconds: 3_000_000_000)
                            throw CancellationError()
                        }
                        _ = try await group.next()
                        group.cancelAll()
                    }
                    appendLog("server.shutdown() 완료")
                } catch is CancellationError {
                    appendLog("server.shutdown() 타임아웃/취소")
                } catch {
                    appendLog("server.shutdown() 예외: \(error.localizedDescription)")
                }
            } else {
                appendLog("server nil: shutdown 생략")
            }

            if let serverTaskRef {
                appendLog("serve task cancel 호출")
                serverTaskRef.cancel()
                do {
                    try await withThrowingTaskGroup(of: Void.self) { group in
                        group.addTask {
                            _ = await serverTaskRef.value
                        }
                        group.addTask {
                            try await Task.sleep(nanoseconds: 3_000_000_000)
                            throw CancellationError()
                        }
                        _ = try await group.next()
                        group.cancelAll()
                    }
                    appendLog("serve task 완료/취소 처리")
                } catch is CancellationError {
                    appendLog("serve task 취소됨")
                } catch {
                    appendLog("serve task 예외: \(error.localizedDescription)")
                }
            } else {
                appendLog("serve task nil: cancel 생략")
            }

            appendLog("서버 종료 완료.")
            status = .idle
        }
    }

    private func appendLog(_ message: String) {
        logs.append(message)
        print("[FastAPI] \(message)")
    }
}
