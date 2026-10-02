# Setting up your computer

This sets up a few things on your computer and then it's done. You won't need to do anything
else afterward.

## What it may do

Depending on what was chosen for you:

- Installs Google Chrome, if it isn't on your computer yet. This download is large, so the
  "Setup Complete" message can take several minutes to appear. Just wait for it.
- Adds a little ad-blocker to Chrome so websites show fewer ads and pop-ups.
- Adds an icon on your Desktop that opens your website with one double-click.

## How to run it

1. Save the file **Install-\<name\>.cmd** somewhere easy to find, like the Desktop or Downloads.
2. Double-click it.
3. Windows will probably show a blue box that says *"Windows protected your PC"* or the
   file's publisher couldn't be verified. This is normal for this kind of file — it just means
   it didn't come from the Windows Store. Click **More info**, then **Run anyway**.
4. A small window may flash for a second — that's normal, let it finish.
5. A message box will pop up saying setup is complete. You can close it, or just wait — it
   closes itself after 30 seconds.

That's it. Nothing else to click, no settings to change.

## If something looks wrong

A file called `install.log` is saved in a folder that opens if you paste this into the little
search box next to the Windows Start button and press Enter:

```
%LOCALAPPDATA%\Appinstaller
```

Send that `install.log` file along when you ask for help — it says exactly what happened.

## Undoing it

If you ever want to remove the ad blocker and the desktop icon, run the matching
**Uninstall-\<name\>.cmd** file the same way (double-click it). Chrome itself stays installed,
so you don't lose your bookmarks.
