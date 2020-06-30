/*
See LICENSE folder for this sample’s licensing information.

Abstract:
Implementation details of the size property to extend the CGImage class.
*/

import CoreGraphics
import ImageIO
import AVFoundation

extension CGImage {
    
    var size: CGSize {
        return CGSize(width: width, height: height)
    }
}
