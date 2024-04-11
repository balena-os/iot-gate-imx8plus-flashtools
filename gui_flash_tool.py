import tkinter as tk
from tkinter import ttk
from tkinter import filedialog
from tkinter import messagebox
import subprocess
import threading
import os

class FlasherGUI:
    def __init__(self, root):
        self.root = root
        self.root.title("IMX8 Board Flasher")

        self.dram_conf = "d2d4"
        self.balena_image = tk.StringVar()
        self.flash_thread = None  # Thread for the flashing process

        self.arch = self.get_system_architecture()
        if self.arch not in ["armv7", "armv8", "aarch64"]:
            self.arch = None  # Default to None if architecture is not recognized

        self.create_widgets()

    def create_widgets(self):
        ttk.Label(self.root, text="Balena Image:").grid(row=0, column=0, padx=5, pady=5, sticky="w")
        ttk.Entry(self.root, textvariable=self.balena_image).grid(row=0, column=1, padx=5, pady=5, sticky="ew")
        ttk.Button(self.root, text="Browse", command=self.browse_image).grid(row=0, column=2, padx=5, pady=5)

        if self.arch:
            ttk.Label(self.root, text="Architecture:").grid(row=1, column=0, padx=5, pady=5, sticky="w")
            ttk.Label(self.root, text=self.arch).grid(row=1, column=1, padx=5, pady=5, sticky="w")

        ttk.Button(self.root, text="Flash", command=self.start_flashing).grid(row=2, column=0, padx=5, pady=10)
        ttk.Button(self.root, text="Cancel", command=self.cancel_flashing).grid(row=2, column=1, padx=5, pady=10)

    def browse_image(self):
        initial_dir = os.getcwd()  # Get the current working directory
        filename = filedialog.askopenfilename(initialdir=initial_dir, filetypes=[("Balena Images", "*.img")])
        if filename:
            self.balena_image.set(filename)


    def start_flashing(self):
        balena_image = self.balena_image.get()

        if not balena_image:
            messagebox.showerror("Error", "Balena Image is required.")
            return

        cmd = f"./run_container.sh -d {self.dram_conf} -i {balena_image}"
        if self.arch:
            cmd += f" -a {self.arch}"

        self.flash_thread = threading.Thread(target=self.flash_board, args=(cmd,))
        self.flash_thread.start()

    def flash_board(self, cmd):
        self.flash_process = subprocess.Popen(cmd, shell=True)
        self.flash_process.wait()
        if self.flash_process.returncode != 0:
            self.root.after(0, lambda: messagebox.showerror("Error", "Failed to flash the board."))
        else:
            self.root.after(0, lambda: messagebox.showinfo("Success", "Board flashed successfully."))


    def cancel_flashing(self):
        if self.flash_process and self.flash_process.poll() is None:
            self.flash_process.terminate()
            messagebox.showinfo("Info", "Flashing process has been cancelled.")
            self.root.after(100, self.show_cancel_message)  # Schedule the message to be shown
        else:
            messagebox.showinfo("Info", "No flashing process is currently running.")


    def show_cancel_message(self):
        messagebox.showerror("Error", "Flashing process was canceled by user.")

    def get_system_architecture(self):
        try:
            arch = subprocess.check_output(["uname", "-m"]).decode().strip()
            if arch.startswith("arm"):
                if "armv7" in arch:
                    return "armv7"
                else:
                    return "armv8"  # Assume ARMv8 if not explicitly armv7 or aarch64
            elif arch.startswith("x86"):
                return "x86"
            else:
                if "aarch64" in arch:
                    return "armv7" # For some reason we need this on the Pi400
                return arch  # Return actual architecture if not arm or x86
        except Exception as e:
            print("Error determining architecture:", e)
            return "Unknown"

def main():
    root = tk.Tk()
    app = FlasherGUI(root)
    root.mainloop()

if __name__ == "__main__":
    main()
