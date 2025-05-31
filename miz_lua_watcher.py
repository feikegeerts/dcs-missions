import os
import time
import zipfile
import shutil
import glob
from watchdog.observers import Observer
from watchdog.events import FileSystemEventHandler

# CONFIGURATION
MIZ_FILE = "Dynamic BVR mission.miz"
MAIN_LUA_FILE = "bvr_main.lua"
LUA_FILES = ["bvr_main.lua", "bvr_mission_core.lua", 
             "bvr_spawner.lua", "bvr_events.lua", "bvr_menu.lua"]
TMP_DIR = "_miz_temp_unpack"

class LuaChangeHandler(FileSystemEventHandler):
    def __init__(self, lua_files, miz_path, tmp_dir):
        self.lua_files = lua_files
        self.miz_path = miz_path
        self.tmp_dir = tmp_dir
        self.last_mtimes = {file: 0 for file in lua_files}
        # Always update the miz on startup to ensure Lua files are up to date
        self.update_miz()

    def on_modified(self, event):
        for lua_file in self.lua_files:
            if event.src_path.endswith(lua_file):
                mtime = os.path.getmtime(lua_file)
                if mtime == self.last_mtimes[lua_file]:
                    return
                self.last_mtimes[lua_file] = mtime
                print(f"Detected change in {lua_file}, updating {self.miz_path}...")
                self.update_miz()
                return

    def update_miz(self):
        # 1. Unzip the .miz file
        if os.path.exists(self.tmp_dir):
            shutil.rmtree(self.tmp_dir)
        with zipfile.ZipFile(self.miz_path, 'r') as zip_ref:
            zip_ref.extractall(self.tmp_dir)
        
        # 2. Find and replace the main lua file inside the extracted folder
        replaced_main = False
        for root, dirs, files in os.walk(self.tmp_dir):
            for file in files:
                if file == os.path.basename(MAIN_LUA_FILE):
                    target_path = os.path.join(root, file)
                    shutil.copy2(MAIN_LUA_FILE, target_path)
                    print(f"Replaced {target_path} with updated {MAIN_LUA_FILE}")
                    replaced_main = True
                    
                    # Also copy all module files to the same directory
                    target_dir = os.path.dirname(target_path)
                    for module_file in self.lua_files:
                        if module_file != MAIN_LUA_FILE and os.path.exists(module_file):
                            module_target = os.path.join(target_dir, os.path.basename(module_file))
                            shutil.copy2(module_file, module_target)
                            print(f"Copied module {module_file} to {module_target}")
        if not replaced_main:
            print(f"WARNING: Did not find {MAIN_LUA_FILE} inside the .miz archive!")
        # 3. Zip the folder back into a .miz file
        backup_path = self.miz_path + ".bak"
        shutil.copy2(self.miz_path, backup_path)
        with zipfile.ZipFile(self.miz_path, 'w', zipfile.ZIP_DEFLATED) as zipf:
            for root, dirs, files in os.walk(self.tmp_dir):
                for file in files:
                    abs_path = os.path.join(root, file)
                    rel_path = os.path.relpath(abs_path, self.tmp_dir)
                    zipf.write(abs_path, rel_path)
        print(f"Updated {self.miz_path} with new {MAIN_LUA_FILE}. Backup saved as {backup_path}.")
        shutil.rmtree(self.tmp_dir)

def main():
    event_handler = LuaChangeHandler(LUA_FILES, MIZ_FILE, TMP_DIR)
    observer = Observer()
    observer.schedule(event_handler, path='.', recursive=False)
    observer.start()
    print(f"Watching BVR Lua files for changes. Press Ctrl+C to stop.")
    try:
        while True:
            time.sleep(1)
    except KeyboardInterrupt:
        observer.stop()
    observer.join()

if __name__ == "__main__":
    main()
