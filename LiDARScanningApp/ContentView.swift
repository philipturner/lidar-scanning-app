//
//  ContentView.swift
//  LiDARScanningApp
//
//  Created by Philip Turner on 11/8/22.
//

import SwiftUI
import MetalKit

struct ContentView: View {
    var body: some View {
      ZStack {
        ARDisplayView(coordinator: Coordinator())
      }
      .ignoresSafeArea(.all)
    }
}

struct ARDisplayView: View {
  @ObservedObject var coordinator: Coordinator
  
  var body: some View {
    let bounds = UIScreen.main.bounds
    
    MetalView(coordinator: coordinator)
      .disabled(false)
      .frame(width: bounds.height, height: bounds.width)
      .rotationEffect(.degrees(90))
      .position(x: bounds.width * 0.5, y: bounds.height * 0.5)
  }
}

struct MetalView: UIViewRepresentable {
  @ObservedObject var coordinator: Coordinator
  
  func makeCoordinator() -> Coordinator {
    coordinator
  }
  
  func makeUIView(context: Context) -> MTKView {
    context.coordinator.view
  }
  
  func updateUIView(_ uiView: MTKView, context: Context) {}
}

