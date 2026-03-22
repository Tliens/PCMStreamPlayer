//
//  ViewController.swift
//  PCMPlayer
//
//  Created by Quinn Von on 2026/3/22.
//

import UIKit

class ViewController: UIViewController {
    // 可以切换为 48HZ、2通道，output_双声道_48000.pcm
    var pcmPlayer = PCMAudioPlayer(sampleRate: 24000,
                                   channels: 1,
                                   bufferTime: 0.2,
                                   chunkTime: 0.2)

    var isPlaying = false
    
    override func viewDidLoad() {
        super.viewDidLoad()

        setupPlayButton()
        
        pcmPlayer.onProgress = {[weak self] time in
            
        }
        
        pcmPlayer.onPlaybackFinished = {[weak self] in
            
        }
    }
    
    func setupPlayButton(){
        let btn = UIButton()
        btn.addTarget(self, action: #selector(playButtonAction), for: .touchUpInside)
        btn.setTitle("播放pcm", for: .normal)
        btn.frame = CGRect(x: 100, y: 100, width: 100, height: 100)
        btn.backgroundColor = .green
        self.view.addSubview(btn)
        
    }
    
    @objc func playButtonAction(){
        if isPlaying{
            self.pcmPlayer.reset()
        }else{
            if let urlToYourPCMFile = Bundle.main.url(forResource: "output", withExtension: "pcm"){
                guard let pcmData = try? Data(contentsOf: urlToYourPCMFile) else { return }
                self.pcmPlayer.appendPCMData(pcmData)
            }
        }
        isPlaying = !isPlaying
    }
}

