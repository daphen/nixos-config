import QtQuick
// Light-mode raised face: the outline is a backing shape, so round ends match straight edges.
Rectangle {
  id: key
  property color outline
  property real ring: 1
  property color faceTop: "#FDFDFD"
  property color faceBottom: "#F3F3F4"
  property int fade: 0
  // Pills: shade both edges around a bright middle so the face reads rounded outwards.
  property bool convex: false
  color: outline
  Behavior on color { enabled: key.fade > 0; ColorAnimation { duration: key.fade; easing.type: Easing.InOutQuad } }
  Rectangle {
    id: bevel
    anchors { fill: parent; margins: key.ring }
    radius: Math.max(0, key.radius - key.ring)
    color: "#FFFFFF"
    Rectangle {
      anchors { fill: parent; topMargin: key.convex ? 0 : 1 }
      radius: bevel.radius
      gradient: key.convex ? convexFace : flatFace
      Gradient {
        id: flatFace
        GradientStop { position: 0; color: key.faceTop }
        GradientStop { position: 1; color: key.faceBottom }
      }
      Gradient {
        id: convexFace
        GradientStop { position: 0; color: "#ECECEE" }
        GradientStop { position: 0.4; color: "#FEFEFE" }
        GradientStop { position: 0.6; color: "#FBFBFB" }
        GradientStop { position: 1; color: "#E6E6E8" }
      }
    }
  }
}
