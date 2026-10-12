#!/usr/bin/env python3
"""A visible, animating, click-reactive Tk window.

Demonstrates the three things a payload needs from this image:
  1. it gets mapped (and decorated, if WM=openbox),
  2. it repaints on its own, so the VNC/websocket traffic is real,
  3. mouse events from the browser arrive as ordinary X events.

WM_CLASS is "canvas-demo" (from className) and the title is too, so the
image's VNC_WINDOW=canvas-demo crop target resolves on either match.
"""
import time
import tkinter as tk

clicks = []


def on_click(event):
    clicks.insert(0, f"{event.x},{event.y} b{event.num}")
    del clicks[4:]
    label.config(text="last clicks (from your browser):  " + "   ".join(clicks))
    canvas.itemconfig(marker, text=f"({event.x}, {event.y})")


def tick():
    canvas.itemconfig(clock, text=time.strftime("%H:%M:%S"))
    # move the dot every frame so a frame-diff liveness check sees motion
    # even in the gap between second boundaries
    x = 40 + (int(time.time() * 5) % 25) * 22
    canvas.coords(dot, x, 118, x + 22, 140)
    root.after(200, tick)


root = tk.Tk(className="canvas-demo")
root.title("canvas-demo")
root.geometry("680x300+80+60")
root.configure(bg="#15151a")

canvas = tk.Canvas(root, width=680, height=180, bg="#101014", highlightthickness=0)
canvas.pack(fill="both", expand=True, padx=10, pady=(10, 0))
canvas.create_rectangle(20, 30, 660, 150, outline="#39d353", width=2)
clock = canvas.create_text(340, 90, text="--:--:--", fill="#ffffff",
                           font=("DejaVu Sans Mono", 44, "bold"))
dot = canvas.create_oval(40, 118, 62, 140, fill="#39d353", outline="")
marker = canvas.create_text(340, 165, text="click anywhere", fill="#aaaaaa",
                            font=("DejaVu Sans", 13))

label = tk.Label(root, anchor="w", fg="#888888", bg="#15151a",
                 text="last clicks: none yet")
label.pack(fill="x", padx=14, pady=(4, 10))

root.bind("<Button>", on_click)
tick()
root.mainloop()
