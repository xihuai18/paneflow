import Foundation
import CoreGraphics

public struct LayoutLink: Sendable {
    public var seam: LayoutSeam
    public var first: String
    public var second: String
    public var frame: CGRect
    public var firstProbe: CGPoint
    public var secondProbe: CGPoint
}

public extension LayoutGeometry {
    func links(assigned: Set<String>) -> [LayoutLink] {
        var result: [LayoutLink] = []
        for seam in seams {
            for first in seam.first.panes where assigned.contains(first) {
                for second in seam.second.panes where assigned.contains(second) {
                    guard let a = panes[first], let b = panes[second] else { continue }
                    let horizontal = seam.axis == .horizontal
                    let firstEdge = horizontal ? a.maxX : a.maxY
                    let secondEdge = horizontal ? b.minX : b.minY
                    let lineStart = horizontal ? seam.line.minX : seam.line.minY
                    let lineEnd = horizontal ? seam.line.maxX : seam.line.maxY
                    guard abs(firstEdge - lineStart) < 0.01, abs(secondEdge - lineEnd) < 0.01 else { continue }
                    let start = horizontal ? max(a.minY,b.minY) : max(a.minX,b.minX)
                    let end = horizontal ? min(a.maxY,b.maxY) : min(a.maxX,b.maxX)
                    let length = min(64,end-start-4)
                    guard length >= 18 else { continue }
                    let middle = (start+end)/2
                    let point = horizontal ? CGPoint(x:seam.line.midX,y:middle) : CGPoint(x:middle,y:seam.line.midY)
                    let frame = horizontal ? CGRect(x:point.x-9,y:point.y-length/2,width:18,height:length)
                        : CGRect(x:point.x-length/2,y:point.y-9,width:length,height:18)
                    let clearance = max(3,(horizontal ? frame.width : frame.height)/2-(secondEdge-firstEdge)/2+3)
                    let firstProbe = horizontal ? CGPoint(x:a.maxX-min(clearance,a.width/2),y:middle)
                        : CGPoint(x:middle,y:a.maxY-min(clearance,a.height/2))
                    let secondProbe = horizontal ? CGPoint(x:b.minX+min(clearance,b.width/2),y:middle)
                        : CGPoint(x:middle,y:b.minY+min(clearance,b.height/2))
                    result.append(.init(seam:seam,first:first,second:second,frame:frame,firstProbe:firstProbe,secondProbe:secondProbe))
                }
            }
        }
        return result
    }
}
