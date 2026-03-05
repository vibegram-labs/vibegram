import UIKit

enum ChatImageEditEventType: String {
  case reply = "mediaReplyRequested"
  case edit = "mediaEditRequested"
  case resend = "mediaResendRequested"
  case sendNew = "mediaSendNewRequested"
}

struct ChatImageEditActionPayload {
  let eventType: ChatImageEditEventType
  let messageId: String?
  let mediaURL: String
  let caption: String?
  let editedImageURL: URL?
}

enum ChatImageEditModule {
  static func presentEditor(
    from presenter: UIViewController,
    messageId: String?,
    mediaURL: String,
    initialImage: UIImage?,
    initialCaption: String?,
    onAction: @escaping (ChatImageEditActionPayload) -> Void
  ) {
    let controller = ChatImageEditViewController(
      messageId: messageId,
      mediaURL: mediaURL,
      initialImage: initialImage,
      initialCaption: initialCaption
    )
    controller.modalPresentationStyle = .fullScreen
    controller.onAction = onAction
    presenter.present(controller, animated: true)
  }
}
