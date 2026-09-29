# AuctionSniper

A small helper for the World of Warcraft Forever auction house. It watches an item you pick, pings you when something is listed cheap, and lets you buy it with one click.

It will not buy for you. Blizzard does not allow addons to place a buyout on their own. AuctionSniper does the watching; you still press Buy.

## Install

1. Quit World of Warcraft if it is open.
2. Copy the whole `AuctionSniper` folder into:

   `World of Warcraft/_classic_era_/Interface/AddOns/`

   When you are done you should have:

   `World of Warcraft/_classic_era_/Interface/AddOns/AuctionSniper/AuctionSniper.toc`

3. At the character select screen, click **AddOns** and make sure **AuctionSniper** is enabled.
4. If it is marked out of date, tick **Load out of date addons**.
5. Log in, walk up to an auctioneer, and open the auction house.

## How to use it

1. Search for the item you want, then click it in the list so its buy page is open.
2. Click **AuctionSniper** in the top-right of the auction house window. A panel opens beside it.
3. Click **Load item** if the panel did not pick it up on its own. The item should appear immediately, even before you touch the price.
4. AuctionSniper looks up the cheapest listing and fills **Buy at or under** with **half** of that price. Change the gold / silver / copper boxes if you want a different cap.
5. Set **Quantity** to how many you want in total. If you want 20 and the first cheap stack is 10, it will keep watching for the other 10.
6. When a listing is at or under your cap, **Buy** lights up and you will hear a ding. Click **Buy**. That click is what places the order.
7. Keep going until you have your full amount, or click **Stop watching**. Closing the AuctionSniper panel also stops it.

If you click a different item in the auction house while the panel is open, AuctionSniper switches to that item.

## The buttons

- **AuctionSniper** (on the auction house) — opens or closes the panel. Closing it stops the watch.
- **Load item** — grab whatever you currently have selected in the auction house.
- **Settings** — how often it refreshes. Slow is the default. Faster checks more often, but the auction house can get busy and skip some scans.
- **Buy** — grey until a deal is in range; click it yourself to buy.
- **Stop watching** — stop scanning, leave the panel open.

## What you will see

The panel shows the cheapest price right now, how many you have bought versus your target, and a short status line.

Under that is a session log: each fill with quantity, unit price, and total, newest first. Average price and gold spent sit above the list so they stay in view while you scroll.

## A few honest limits

- You have to be at the auction house with the window open.
- You have to click Buy (or use a click) yourself. The addon cannot press it for you.
- Cheap stacks disappear fast. AuctionSniper can only see a listing after its next refresh, so you will still lose some races. Faster refresh in Settings helps a little; it cannot see the market live.
- If the price jumps after you click Buy, the purchase is cancelled so you do not overpay.

## Chat commands

You do not need these. They are here if you want them.

- `/as` — open or close the panel
- `/as load` — load the selected auction house item
- `/as settings` — open settings
- `/as stop` — stop watching
