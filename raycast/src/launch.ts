import { closeMainWindow, open, showToast, Toast } from "@raycast/api";

export async function launch(action: "open" | "advanced" | "refresh") {
  try {
    await closeMainWindow();
    await open(`headphonebar://${action}`, "local.headphonebar.app");
  } catch (error) {
    await showToast({
      style: Toast.Style.Failure,
      title: "Could not open HeadphoneBar",
      message: "Install a HeadphoneBar build with Raycast support in Applications and open it once.",
      primaryAction: { title: "Open Project", onAction: () => open("https://github.com/michaeldeby/HeadphoneBar") },
    });
  }
}
