import SwiftUI

struct AppIconView: View {
    var body: some View {
        ZStack {
            // A clean, solid background color that works perfectly on iOS 14+
            Color(red: 0.6, green: 0.4, blue: 0.2)
                .edgesIgnoringSafeArea(.all)
            
            VStack {
                Text("🪑")
                    .font(.system(size: 80))
                Text("CarpetChair")
                    .font(.headline)
                    .foregroundColor(.white)
            }
        }
        .frame(width: 120, height: 120)
        .cornerRadius(24)
    }
}

struct AppIconView_Previews: PreviewProvider {
    static var previews: some View {
        AppIconView()
    }
}
