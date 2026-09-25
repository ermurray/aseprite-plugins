import { join } from "node:path";
import { ConversationStore } from "./conversations.js";
import { PROJECT_DIR } from "./project.js";

/** One ConversationStore per chats folder, shared by all sessions so saves stay serialised. */
export class StoreRegistry {
  private stores = new Map<string, ConversationStore>();

  constructor(private globalDir: string) {}

  get(root: string | null): ConversationStore {
    const dir = root ? join(root, PROJECT_DIR, "chats") : this.globalDir;
    let store = this.stores.get(dir);
    if (!store) {
      store = new ConversationStore(dir);
      this.stores.set(dir, store);
    }
    return store;
  }
}
