//
//  ViewController.swift
//  VNDetectHumanBodyPose
//
//  Created by Den Jo on 2020/06/29.
//

import UIKit
import Vision
import AVFoundation

final class ViewController: UIViewController {

    // MARK: - Value
    // MARK: Private
    private lazy var detectTrajectoryRequest = VNDetectTrajectoriesRequest(frameAnalysisSpacing: .zero, trajectoryLength: 15)
    private let videoDataOutputQueue = DispatchQueue(label: "CameraFeedDataOutput", qos: .userInitiated, attributes: [], autoreleaseFrequency: .workItem)
    
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
        dataOutput.videoSettings = [String(kCVPixelBufferPixelFormatTypeKey): Int(kCVPixelFormatType_420YpCbCr8BiPlanarFullRange)]
        dataOutput.setSampleBufferDelegate(self, queue: videoDataOutputQueue)
        
        let captureConnection = dataOutput.connection(with: .video)
        captureConnection?.preferredVideoStabilizationMode = .standard
        captureConnection?.isEnabled = true // Always process the frames
        
        session.commitConfiguration()
        return session
    }()
    
    private lazy var previewLayer: AVCaptureVideoPreviewLayer = {
        let previewLayer = AVCaptureVideoPreviewLayer(session: self.session ?? AVCaptureSession())
        previewLayer.frame        = view.frame
        previewLayer.videoGravity = .resizeAspectFill
        return previewLayer
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
    
    
    
    // MARK: - View Life Cycle
    override func viewDidLoad() {
        super.viewDidLoad()
        
        setSession()
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        
        previewLayer.frame = view.frame
        previewLayer.connection?.videoOrientation = videoOrientation
    }
    

    
    // MARK: - Function
    // MARK: Private
    private func setSession() {
        guard let session = session else { return }
        
        session.startRunning()
        view.layer.insertSublayer(previewLayer, at: 0)
    }
    
    private func bodyPoseHandler(request: VNRequest, error: Error?) {
        guard let observations = request.results as? [VNRecognizedPointsObservation] else { return }
        
        // Process each observation to find the recognized body pose points.
        DispatchQueue.main.async { observations.forEach { self.processObservation($0) } }
    }
    
    private func processObservation(_ observation: VNRecognizedPointsObservation) {
        
        // Retrieve all torso points.
        guard let recognizedPoints = try? observation.recognizedPoints(forGroupKey: .bodyLandmarkRegionKeyTorso) else { return }
        
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
        
        print(imagePoints)
        // Draw the points onscreen.
//        draw(points: imagePoints)
    }
    
    
    
}



// MARK: - AVCaptureVideoDataOutputSampleBuffer Delegate
extension ViewController: AVCaptureVideoDataOutputSampleBufferDelegate {
    
    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        let requestHandler = VNImageRequestHandler(cmSampleBuffer: sampleBuffer, orientation: .up, options: [:])
        let detectHumanBodyPoseRequest = VNDetectHumanBodyPoseRequest(completionHandler: bodyPoseHandler)
    
        do {
            try requestHandler.perform([detectHumanBodyPoseRequest])
            
            
        } catch {
            print(error.localizedDescription)
        }
    }
}
