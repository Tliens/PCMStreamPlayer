import AVFoundation

class PCMAudioPlayer {
    
    // 播放结束回调
    var onPlaybackFinished: (() -> Void)?
    // 进度回调，用于字幕处理，单位：秒（带小数）
    var onProgress: ((Double) -> Void)?
    
    private let engine = AVAudioEngine()
    private let playerNode = AVAudioPlayerNode()
    
    // 需要根据pcm音频手动配置
    private var audioFormat: AVAudioFormat!
    private var sampleRate: Double = 48000
    private var channels: AVAudioChannelCount = 2

    // MARK: - Buffer Control
    private var cacheData = Data()
    private let queue = DispatchQueue(label: "pcm.stream.player")
    // 总缓冲，网络防抖，攒一攒再播
    private var bufferTime: Double = 0.2
    // 每次喂，延迟
    private var chunkTime: Double = 0.1
    private var scheduledFrames: AVAudioFramePosition = 0
    private var startSampleFrame: AVAudioFramePosition?
    
    private var isFinishing = false
    
    private var progressTimer: DispatchSourceTimer?
    
    private var debug_receivedTime: Double = 0

    init(sampleRate:Double, channels: AVAudioChannelCount, bufferTime: Double, chunkTime: Double) {
        self.sampleRate = sampleRate
        self.channels = channels
        self.bufferTime = bufferTime
        self.chunkTime = chunkTime
        setupAudio()
    }
    
    private func setupAudio() {
        audioFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: sampleRate,
            channels: channels,
            interleaved: false
        )
        
        engine.attach(playerNode)
        engine.connect(playerNode, to: engine.mainMixerNode, format: audioFormat)
        
        do {
            try engine.start()
        } catch {
            print("Engine start failed: \(error)")
        }
    }
    
    // MARK: - Public API（喂数据）
    func appendPCMData(_ data: Data) {
        
        // 打印本次接收到的数据量
        let chunkSize = data.count
        let durationMs = Float(chunkSize) / 48.0  // 24kHz, 16bit, 单声道: 48字节/ms
        
        print("""
            收到音频数据块:
            - 数据大小: \(chunkSize) 字节
            - 音频时长: \(String(format: "%.1f", durationMs)) ms
            - 样本数量: \(chunkSize / 2) 个
            """)
        
        if debug_receivedTime == 0{
            debug_receivedTime = Date().timeIntervalSince1970
        }
        queue.async {
            self.cacheData.append(data)
            self.scheduleIfNeeded()
        }
    }

    func reset() {
        queue.async { [weak self] in
            guard let self = self else { return }
            self.playerNode.stop()
            self.debug_receivedTime = 0
            self.scheduledFrames = 0
            self.startSampleFrame = nil
            self.isFinishing = false
            self.cacheData.removeAll()
            self.stopProgressTimer()
            
        }

    }
    
    // 获取当前还剩多少帧没有播放
    private func remainingFrames() -> AVAudioFramePosition {
        guard let nodeTime = playerNode.lastRenderTime,
              let playerTime = playerNode.playerTime(forNodeTime: nodeTime) else {
            return 0
        }
        
        let currentSampleFrame = AVAudioFramePosition(playerTime.sampleTime)
        
        // 记录起点（第一次播放时）
        if startSampleFrame == nil && scheduledFrames > 0 {
            startSampleFrame = currentSampleFrame
        }
        
        guard let start = startSampleFrame else {
            return 0
        }
        
        //已播放帧数
        let played = currentSampleFrame - start
        
        //滑动窗口，避免scheduledFrames无限增大
        if played > Int(sampleRate * 2) {
            if scheduledFrames > played {
                scheduledFrames -= played
            } else {
                scheduledFrames = 0
            }
            
            startSampleFrame = currentSampleFrame
            return scheduledFrames
        }
        
        //剩余帧
        let remainFrames = scheduledFrames - played
        
        return max(0, remainFrames)
    }
    
    private func scheduleIfNeeded() {
        
        let bytesPerSample = 2
        let bytesPerFrame = bytesPerSample * Int(channels)


        // 启动缓冲
        if !playerNode.isPlaying {
            let minStartBytes = Int(sampleRate * bufferTime) * bytesPerFrame
            if cacheData.count < minStartBytes {
                return
            }
        }

        // 每次投喂数据
        let chunkBytes = Int(sampleRate * chunkTime) * bytesPerFrame

        // 是否尾巴
        let isEnding = cacheData.count < chunkBytes
        
        // 当前剩余时间
        let remain = remainingFrames()
        let remainingTime = Double(remain) / sampleRate

        if !isEnding && remainingTime > bufferTime {
            return
        }

        guard isEnding || cacheData.count >= chunkBytes else {
            return
        }
        
        if isEnding, cacheData.count <= 0{
            //没有数据
            checkPlaybackFinished()
            return
        }
        
        // 切数据
        let size = isEnding ? cacheData.count : chunkBytes
        let chunk = cacheData.prefix(size)
        cacheData.removeFirst(size)
        
        guard let format = audioFormat else { return }
        
        let frameCount = UInt32(chunk.count / (bytesPerSample * Int(channels)))
        
        let (leftFloat, rightFloat) = convertInt16ToFloat32(chunk)

        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount) else {
            return
        }
        
        buffer.frameLength = frameCount
        
        // 写入左声道
        let leftChannel = buffer.floatChannelData![0]
        for i in 0..<Int(frameCount) {
            leftChannel[i] = leftFloat[i]
        }

        if channels == 2{
            // 写入右声道
            let rightChannel = buffer.floatChannelData![1]
            for i in 0..<Int(frameCount) {
                rightChannel[i] = rightFloat[i]
            }
        }
        
        scheduledFrames += AVAudioFramePosition(buffer.frameLength)
            
        playerNode.scheduleBuffer(buffer) { [weak self] in
            guard let self = self else { return }
            
            self.queue.async {
                self.scheduleIfNeeded()
            }
        }
        
        if !playerNode.isPlaying {
            let debug_diff = Date().timeIntervalSince1970 - debug_receivedTime

            print("PCMAudioPlayer 本地处理耗时：\(Int(debug_diff * 1000)) ms ")

            playerNode.play()
            startProgressTimer()
        }

        checkPlaybackFinished()
    }
    
    private func checkPlaybackFinished() {
        if cacheData.isEmpty && !isFinishing {
            isFinishing = true
            
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                print("PCMAudioPlayer 播放结束")
                self.onPlaybackFinished?()
                self.stopProgressTimer()
            }
        }
    }
    
    private func stopProgressTimer() {
        progressTimer?.cancel()
        progressTimer = nil
    }
    
    private func startProgressTimer() {
        if progressTimer != nil { return }
        
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now(), repeating: 0.02) // 20ms
        
        timer.setEventHandler { [weak self] in
            guard let self = self else { return }
            
            let time = self.currentPlaybackTime()
            self.onProgress?(time)
        }
        
        timer.resume()
        progressTimer = timer
    }
    
    private func currentPlaybackTime() -> Double {
        guard let nodeTime = playerNode.lastRenderTime,
              let playerTime = playerNode.playerTime(forNodeTime: nodeTime),
              let start = startSampleFrame else {
            return 0
        }
        
        let currentSampleFrame = AVAudioFramePosition(playerTime.sampleTime)
        let playedFrames = currentSampleFrame - start
        
        return Double(playedFrames) / sampleRate
    }
}

extension PCMAudioPlayer{

    // 用 32768，不是 Int16.max
    // Int16.max = 32767
    // 但 PCM 对称范围是 [-32768, 32767]
    // 用 32767 会产生轻微失真（可能导致杂音/爆音）
    
    private func convertInt16ToFloat32(_ data: Data) -> ([Float], [Float]) {
        let count = data.count / (2 * Int(channels))
        var left = [Float](repeating: 0, count: count)
        var right = [Float](repeating: 0, count: count)
        
        data.withUnsafeBytes { rawPtr in
                for i in 0..<count {
                    let leftSample = rawPtr.load(fromByteOffset: i * 2 * Int(channels) + 0, as: Int16.self)
                    left[i] = Float(leftSample) / 32768.0
                    
                    if channels == 2{
                        let rightSample = rawPtr.load(fromByteOffset: i * 2 * Int(channels) + 2, as: Int16.self)
                        right[i] = Float(rightSample) / 32768.0
                    }
                }
            }
        return (left, right)
    }

}
/*
 
 常见问题和原因
 
 1️⃣ 声音变快 / 变慢
采样率不匹配
 
 2️⃣ 没声音
检查：iOS 静音开关、AVAudioSession

 3️⃣ 声音像“电流声”
数据不是 PCM（最常见）
 
 4️⃣ 声音断断续续
buffer 太小 / 喂数据不连续
 
 5️⃣ 声音像机器人
声道 / 位深解析错

 */


/*
 使用：
 // pcmPlayer为成员变量
 var pcmPlayer = PCMAudioPlayer()
 
 if let urlToYourPCMFile = Bundle.main.url(forResource: "output", withExtension: "pcm"){
     guard let pcmData = try? Data(contentsOf: urlToYourPCMFile) else { return }
     self.pcmPlayer.streamPCMData(pcmData)
 }
}
 */

/*
 output.pcm 的音频编码参数为： pcm_s16le, 24000 Hz, mono, s16, 384 kb/s
 
 pcm_s16le
 
 PCM：脉冲编码调制，是一种未压缩的原始音频数据格式，保真度最高。
 s16：每个采样点用16位（2字节）有符号整数表示。位深越高，动态范围越大，细节越丰富。
 le：字节序为小端序，即低位字节在前，这是最常用的存储方式。
 
 24000 Hz 采样率：每秒对声音采集24000次。根据奈奎斯特采样定理，它能记录最高12000Hz的声音，完全覆盖了人声的核心频率范围。
 mono 单声道：只有一个音频通道。所有声音都从一个点发出，没有立体声的左右区分。
 
 384 kb/s
 比特率：音频流每秒钟的数据量为384千比特。对于PCM格式，这是一个固定值，计算公式为：采样率 × 位深 × 声道数。即 24000 Hz × 16位 × 1声道 = 384,000 bps。

 PCM 格式（必须严格匹配你的数据）
 AVAudioEngine.mainMixerNode 默认不支持 Int16 格式输入，必须为 pcmFormatFloat32
 pcmFormatFloat32，但是由于示例的 pcm：  output.pcm，为 pcm_s16le，16的位深，所以转 buffer 时提供了 convertInt16ToFloat32
 interleaved = false（非交错）数据存储
 关键细节：如果channels为 1， 这里只取第一个声道的数据：
 
 let leftChannel = buffer.floatChannelData![0]

*/



/*
 FFmpeg 常用命令
 
 // mp3 转音频
 ffmpeg -i input.mp3 -f s16le output.pcm
 
 // 查看输入文件的详细情
 ffprobe -i input.mp3
 */
