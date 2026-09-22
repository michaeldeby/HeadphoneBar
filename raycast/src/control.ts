import { showToast, Toast } from "@raycast/api";
import { randomUUID } from "node:crypto";
import { mkdir, writeFile, readFile, rm } from "node:fs/promises";
import { homedir } from "node:os";
import { join } from "node:path";
import { execFile } from "node:child_process";
import { promisify } from "node:util";

export type Setting = "anc-on" | "anc-off" | "transparency" | "output-bluetooth" | "output-btd700";
export async function control(action: Setting) {
  const toast = await showToast({ style: Toast.Style.Animated, title: "Changing headphone setting…" });
  const directory = join(homedir(), "Library/Application Support/HeadphoneBar/Raycast");
  const id = randomUUID();
  const request = join(directory, `${id}.request.json`);
  const response = join(directory, `${id}.response.json`);
  try {
    await mkdir(directory, { recursive: true, mode: 0o700 });
    await writeFile(request, JSON.stringify({ action, createdAt: Date.now() / 1000 }), { mode: 0o600, flag: "wx" });
    await promisify(execFile)("/usr/bin/open", ["-g", "-b", "local.headphonebar.app", `headphonebar://command/${id}`]);
    const deadline = Date.now() + 80000;
    while (Date.now() < deadline) {
      let data: string;
      try { data = await readFile(response, "utf8"); }
      catch (error) {
        if ((error as NodeJS.ErrnoException).code !== "ENOENT") throw error;
        await new Promise((resolve) => setTimeout(resolve, 100));
        continue;
      }
      const result: { success: boolean; message: string } = JSON.parse(data);
      if (typeof result.success !== "boolean" || typeof result.message !== "string") throw new Error("Invalid reply from HeadphoneBar.");
      toast.style = result.success ? Toast.Style.Success : Toast.Style.Failure;
      toast.title = result.success ? "Headphone setting updated" : "Could not change headphone setting";
      toast.message = result.message;
      return;
    }
    throw new Error("No confirmation received. Check HeadphoneBar before retrying; it may need updating or Bluetooth permission.");
  } catch (error) {
    toast.style = Toast.Style.Failure;
    toast.title = "Could not change headphone setting";
    toast.message = error instanceof Error ? error.message : String(error);
  } finally {
    await Promise.all([rm(request, { force: true }), rm(response, { force: true })]).catch(() => {});
  }
}
