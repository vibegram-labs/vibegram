import UIKit

let seg = UISegmentedControl(items: ["A", "B"])
print(seg.subviews.map({ String(describing: type(of: $0)) }))

