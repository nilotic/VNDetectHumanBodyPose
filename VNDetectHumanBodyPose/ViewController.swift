//
//  ViewController.swift
//  VNDetectHumanBodyPose
//
//  Created by Den Jo on 2020/06/29.
//

import UIKit
import Vision
import AVFoundation
import PhotosUI
import CoreVideo
import VideoToolbox

final class ViewController: UIViewController {

    // MARK: - IBOutlet
    @IBOutlet private var previewImageView: PoseImageView!
    
    
    
    
    // MARK: - Value
    // MARK: Private
    private lazy var detectTrajectoryRequest = VNDetectTrajectoriesRequest(frameAnalysisSpacing: .zero, trajectoryLength: 15)
    private let queue = DispatchQueue(label: "CameraFeedDataOutput", qos: .userInitiated, attributes: [], autoreleaseFrequency: .workItem)
    
    private lazy var session: AVCaptureSession? = {
        // Create device discovery session for a wide angle camera
        let discoverySession = AVCaptureDevice.DiscoverySession(deviceTypes: [.builtInWideAngleCamera], mediaType: .video, position: .unspecified)
        
        
        // Select a video device, make an input
        let session = AVCaptureSession()
        guard let videoDevice = discoverySession.devices.first, let deviceInput = try? AVCaptureDeviceInput(device: videoDevice) else { return nil }
        session.beginConfiguration()
        
        // We prefer a 1080p video capture but if camera cannot provide it then fall back to highest possible quality
        session.sessionPreset = videoDevice.supportsSessionPreset(.hd1920x1080) ? .hd1920x1080 : .high
        
        
        // Add a video input
        guard session.canAddInput(deviceInput) else { return nil }
        session.addInput(deviceInput)
        
        let dataOutput = AVCaptureVideoDataOutput()
        guard session.canAddOutput(dataOutput) else { return nil }
        session.addOutput(dataOutput)
        
        // Add a video data output
        dataOutput.alwaysDiscardsLateVideoFrames = true
        dataOutput.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarFullRange]
        dataOutput.setSampleBufferDelegate(self, queue: queue)
        
        let captureConnection = dataOutput.connection(with: .video)
        captureConnection?.preferredVideoStabilizationMode = .standard
        captureConnection?.isEnabled = true // Always process the frames
        
        session.commitConfiguration()
        return session
    }()
    
    private var videoOrientation: AVCaptureVideoOrientation {
        switch view.window?.windowScene?.interfaceOrientation {
        case .landscapeLeft:        return .landscapeLeft
        case .landscapeRight:       return .landscapeRight
        case .portrait:             return .portrait
        case .portraitUpsideDown:   return .portraitUpsideDown
        default:                    return .portrait
        }
    }
    
    private var player = AVPlayer()
    private var timeObserver: Any? = nil
   
    private lazy var detectHumanBodyPoseRequest: VNDetectHumanBodyPoseRequest = {
        return VNDetectHumanBodyPoseRequest(completionHandler: bodyPoseHandler)
    }()
    
    private lazy var poseNet: PoseNet? = {
        let poseNet = PoseNet()
        poseNet?.delegate = self
        return poseNet
    }()
    
    
    /// The algorithm the controller uses to extract poses from the current frame.
    private var algorithm: Algorithm = .multiple

    /// The set of parameters passed to the pose builder when detecting poses.
    private var poseBuilderConfiguration = PoseBuilderConfiguration()

    private var currentFrame: CGImage? = nil
    
    
    
    // MARK: - View Life Cycle
    override func viewDidLoad() {
        super.viewDidLoad()
        
        setLayers()
    }

    
    
    // MARK: - Function
    // MARK: Private
    private func setLayers() {
        previewImageView.layer.zPosition = 10
    }
        
    private func read(asset: AVAsset) -> [CMSampleBuffer] {
        guard let assetReader = try? AVAssetReader(asset: asset), let track = asset.tracks(withMediaType: .video).last else {
            log(.error, "Failed to get an assetReader")
            return []
        }
        
        let outputSettings = [kCVPixelBufferPixelFormatTypeKey as String : kCVPixelFormatType_420YpCbCr8BiPlanarFullRange]
        let assetReaderTrackOutput = AVAssetReaderTrackOutput(track: track, outputSettings: outputSettings)
        
        guard assetReader.canAdd(assetReaderTrackOutput) == true else {
            log(.error, "Failed to add a trackOutput")
            return []
        }
        
        assetReader.add(assetReaderTrackOutput)
        assetReader.startReading()
        
        var sampleBuffers = [CMSampleBuffer]()
        var isEmpty = false
        
        while isEmpty == false {
            guard let sampleBuffer = assetReaderTrackOutput.copyNextSampleBuffer() else {
                isEmpty = true
                break
            }
            
            sampleBuffers.append(sampleBuffer)
        }
        
        return sampleBuffers
    }
    
    private func request(sampleBuffer: CMSampleBuffer) {
        let requestHandler = VNImageRequestHandler(cmSampleBuffer: sampleBuffer, orientation: .up, options: [:])
        do { try requestHandler.perform([detectHumanBodyPoseRequest]) } catch { log(.error, error.localizedDescription) }
    }
    
    private func bodyPoseHandler(request: VNRequest, error: Error?) {
        guard let observations = request.results as? [VNRecognizedPointsObservation] else {
            log(.error, "Failed to get results")
            return
        }
        
        // Process each observation to find the recognized body pose points.
        DispatchQueue.main.async { observations.forEach { self.processObservation($0) } }
    }
    
    private func processObservation(_ observation: VNRecognizedPointsObservation) {
        // Retrieve all torso points.
        guard let recognizedPoints = try? observation.recognizedPoints(forGroupKey: .bodyLandmarkRegionKeyTorso) else {
            log(.error, "Failed to get recognized points")
            return
        }
        
        // Torso point keys in a clockwise ordering.
        let torsoKeys: [VNRecognizedPointKey] = [.bodyLandmarkKeyNeck,
                                                 .bodyLandmarkKeyRightShoulder,
                                                 .bodyLandmarkKeyRightHip,
                                                 .bodyLandmarkKeyRoot,
                                                 .bodyLandmarkKeyLeftHip,
                                                 .bodyLandmarkKeyLeftShoulder]
        
        // Retrieve the CGPoints containing the normalized X and Y coordinates.
        let imagePoints: [CGPoint] = torsoKeys.compactMap {
            guard let point = recognizedPoints[$0], point.confidence > 0 else { return nil }
            
            // Translate the point from normalized-coordinates to image coordinates.
            return VNImagePointForNormalizedPoint(point.location, Int(view.frame.width), Int(view.frame.height))
        }
        
        log(.info, imagePoints)
        // Draw the points onscreen.
//        draw(points: imagePoints)
    }
    
    private func draw(sampleBuffer: CMSampleBuffer) {
        guard let pixelBuffer = sampleBuffer.imageBuffer else { return }
        
        // Attempt to lock the image buffer to gain access to its memory.
        guard CVPixelBufferLockBaseAddress(pixelBuffer, .readOnly) == kCVReturnSuccess else { return }
        
        // Create Core Graphics image placeholder.
        var capturedImage: CGImage?
        
        // Create a Core Graphics bitmap image from the pixel buffer.
        VTCreateCGImageFromCVPixelBuffer(pixelBuffer, options: nil, imageOut: &capturedImage)
        
        // Release the image buffer.
        CVPixelBufferUnlockBaseAddress(pixelBuffer, .readOnly)
        
        DispatchQueue.main.sync {
            guard self.currentFrame == nil, let image = capturedImage else { return }
            
            self.currentFrame = image
            self.poseNet?.predict(image)
        }
    }
    
    
    
    // MARK: - Event
    @IBAction private func cameraBarButtonItemAction(_ sender: UIBarButtonItem) {
        guard let session = session else {
            log(.error, "Failed to get a session")
            return
        }
        
        session.startRunning()
    }
    
    @IBAction private func searchBarButtonItemAction(_ sender: UIBarButtonItem) {
        var configuration = PHPickerConfiguration(photoLibrary: PHPhotoLibrary.shared())
        configuration.filter         = .videos
        configuration.selectionLimit = 1
        
        let picker = PHPickerViewController(configuration: configuration)
        picker.delegate = self
        
        DispatchQueue.main.async { self.present(picker, animated: true) }
    }
}



// MARK: - AVCaptureVideoDataOutputSampleBuffer Delegate
extension ViewController: AVCaptureVideoDataOutputSampleBufferDelegate {
    
    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        draw(sampleBuffer: sampleBuffer)
    }
}



// MARK: - PHPickerViewControllerDelegate
extension ViewController: PHPickerViewControllerDelegate {
    
    func picker(_ picker: PHPickerViewController, didFinishPicking results: [PHPickerResult]) {
        picker.dismiss(animated: true)
        
        let assets = PHAsset.fetchAssets(withLocalIdentifiers: results.compactMap(\.assetIdentifier), options: nil)
        
        guard let first = assets.firstObject else {
            log(.error, "Failed to get the first asset")
            return
        }
        
        let options = PHVideoRequestOptions()
        options.deliveryMode           = .highQualityFormat
        options.isNetworkAccessAllowed = true
        
        PHImageManager.default().requestAVAsset(forVideo: first, options: options) { (asset, audioMix, info) in
            guard let asset = asset else {
                log(.error, "Failed to get an asset")
                return
            }
            
            self.player = AVPlayer(playerItem: AVPlayerItem(asset: asset))
            
            /*
            let imageGenerator = AVAssetImageGenerator(asset: asset)
            imageGenerator.appliesPreferredTrackTransform = true
            
            self.timeObserver = self.player.addPeriodicTimeObserver(forInterval: CMTime(value: 1, timescale: 600), queue: self.queue) { time in
                imageGenerator.generateCGImagesAsynchronously(forTimes: [NSValue(time: time)]) { (time, image, time2, result, error) in
                    guard let image = image else { return }

                    DispatchQueue.main.sync {
                        guard self.currentFrame == nil else { return }

                        self.currentFrame = image
                        self.poseNet?.predict(image)
                    }
                }
            }
            */
            
            let sampleBuffers = self.read(asset: asset)
            guard sampleBuffers.isEmpty == false else { return }
        
            var count = 0
            self.timeObserver = self.player.addPeriodicTimeObserver(forInterval: CMTime(value: 1, timescale: 96), queue: self.queue) { time in
                log(.info, "\(sampleBuffers.count) \(count)")
                
                self.draw(sampleBuffer: sampleBuffers[min(count, sampleBuffers.count - 1)])
                count += 1
            }
            
            self.player.play()
        }
    }
}



// MARK: - PoseNet Delegate
extension ViewController: PoseNetDelegate {
    
    // https://developer.apple.com/documentation/coreml/detecting_human_body_poses_in_an_image
    func poseNet(_ poseNet: PoseNet, didPredict predictions: PoseNetOutput) {
        defer { currentFrame = nil }

        guard let currentFrame = currentFrame else { return }
        let poseBuilder = PoseBuilder(output: predictions, configuration: poseBuilderConfiguration, inputImage: currentFrame)
        let poses = algorithm == .single ? [poseBuilder.pose] : poseBuilder.poses

        previewImageView.show(poses: poses, on: currentFrame)
    }
}
