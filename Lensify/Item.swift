//
//  Item.swift
//  Lensify
//
//  Created by Jake Reinhart on 7/25/24.
//

import Foundation
import SwiftData

@Model
final class Item {
    var timestamp: Date
    
    init(timestamp: Date) {
        self.timestamp = timestamp
    }
}
