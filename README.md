# visionOS 27 + iOS 27 Object Tracking Updates Demo

Object tracking got its first update since it arrived in visionOS 2 – the improvements include:
1. High frame rate tracking
2. An extended training mode in Create ML which results in more accurate tracking
3. A metric pose for use cases that need the highest accuracy
4. Better (and faster-trained) `.referenceobject` files when using macOS 27's Create ML
5. Object tracking is now available on iOS

This repo serves as a demo of 1, 2, 4, and 5 above to make an app that lets the Apple Vision Pro serve as my eyes so I can complete a task blind.

The full demo video with sound is [here](https://youtu.be/j4cPzciaW-I).

The write-up, with the training numbers and lots more details on what I found, is [over here](https://vision.engineer/posts/object-tracking-updates-in-visionOS-27-and-iOS-27/).

Here's a clip of the demo:

![visionOS 27 iOS 27 Object Tracking Demo Clip](https://github.com/user-attachments/assets/ece7f220-3d0d-4f6c-b6b3-cd9dc2ef3a62)

**Comparison of standard vs. high frame rate tracking:** I used the 2% blue milk carton and the full fat red milk carton to compare the old standard-rate tracking vs. the new high frame rate tracking. The blue milk carton is a two-year-old reference object from my [visionOS 2 demo](https://github.com/robomex/visionOS-2-Object-Tracking-Demo), loaded at the default rate. The red milk carton is trained with macOS 27's Create ML in extended mode and loaded with high frame rate tracking. Same kind of object, same table, and a semitransparent overlay on each to make the differences more obvious. The blue milk carton is effectively a worst-case scenario (macOS 15 trainer, standard training mode, trained on all angles, standard frame rate tracking) vs. the red milk carton's best-case scenario (macOS 27 trainer, extended training mode, trained on upright angles, high frame rate tracking).

**Arranging items placed on iOS solely by listening to audio played on visionOS (i.e. place items blind):** the two devices first calibrate by each recognizing the red milk carton. Then someone on an iPhone drags three items from a carousel onto the table. A ghost of each lands on the real table in both devices' view. A second person, wearing the Vision Pro with eyes closed and guided by spatial audio, puts the real items where the ghosts are.

**The floating Persona facecam:** the Vision Pro wearer's Persona floats in the corner of the recording using my [PersonaCam](https://github.com/robomex/PersonaCam) package. PersonaCam is a head-anchored Persona facecam for visionOS, which can be added to projects in two lines of code. 

## Two things found on device that I didn't see in Apple's documentation
- A default-rate object anchor never reports that the object left view – but a high frame rate object's anchor is removed when said object is no longer in-view
- Six objects is the most the Vision Pro can track at high frame rate at once

## Requirements
- Xcode 27
- An iPhone on iOS 27
- An Apple Vision Pro on visionOS 27

## Build
1. Choose your Apple Developer account in Signing & Capabilities (the bundle identifier appends your team ID to prevent collisions)
2. Build and run on the iPhone
3. Build and run on the Vision Pro

## Run
1. Launch both apps. 
2. Point both devices at the red milk carton and hold still for a second to calibrate the devices.
3. On the iPhone, press and hold an item in the carousel and drag it onto the table. Three items make the meal, in the order you drop them.
4. On the Vision Pro, close your eyes and follow the sound. A low pulsing tone plays from the item you're after, faster and higher as your hand gets close; a sting plays when you touch it. Pick it up and a brighter tone plays from where it needs to be placed, faster and higher as you near it. The placement tone holds steady for a second when the object is correctly placed, then a chime plays. A soft tick means the Vision Pro can't see the item or your hand right now.

If you reinstall the app on either device, its certificate changes and the other device will refuse it. Tap **Forget Paired Device** on both, then let them reconnect.

## The objects
I live in Chicago. The 2024 pair came from a Jewel in June 2024, the other six from a Jewel in August 2026. Your local packaging may vary and prevent recognition.

1. [Fairlife 2% ultra-filtered milk](https://fairlife.com/ultra-filtered-milk/reduced-fat-2-percent-milk/) (the blue carton, from 2024)
2. [Fairlife whole ultra-filtered milk](https://fairlife.com/ultra-filtered-milk/whole-milk/) (the red carton)
3. [Cap'n Crunch, large size](https://www.thefreshgrocer.com/sm/pickup/rsid/2000/product/capn-crunch-sweetened-corn-&-oat-cereal-large-size-18-oz-id-00030000573242/) (from 2024)
4. [Quaker Protein Granola, Maple & Brown Sugar](https://www.quakeroats.com/products/protein-granola/quaker-protein-granola-maple-brown-sugar)
5. [OREO frozen dairy dessert bars, 5-pack](https://www.thefreshgrocer.com/product/oreo-frozen-dairy-dessert-bars-5-count-137-fl-oz-00072554276569)
6. [Chobani nonfat plain Greek yogurt, 32 oz](https://www.chobani.com/products/yogurt/greek/nonfat-plain-large-size-tub)
7. [Fruit Roll-Ups, Strawberry Blast](https://www.fruitrollups.com/products/strawberry-blast)
8. [Signature Select unsweetened apple sauce, 23.5 oz bottle](https://www.jewelosco.com/shop/product-details.960017265.html)

## Using your own objects
1. Scan the object into a USDZ. I used Apple's [Object Capture sample app](https://developer.apple.com/documentation/realitykit/scanning-objects-using-object-capture) on an iPhone.
2. Train a `.referenceobject` from the USDZ in macOS 27's Create ML. Standard mode took about four hours per object on an M4 Max with 128 GB of RAM; extended mode about seven times longer.
3. Drop the `.referenceobject` into `ObjectTrackingUpdates/Reference Objects/` and add the item to `DemoItemCatalog` in `Shared/DemoItem.swift`, with its file name, whether it loads at high frame rate, and whether it's a carton or a meal item. Six is the max number of objects that run at high frame rate at once.

## Credits
The networking is based on Apple's [Connecting iPadOS and visionOS apps over the local network](https://developer.apple.com/documentation/visionos/connecting-ipados-and-visionos-apps-over-the-local-network) sample, vendored here as the `PeerConnection` package with a reconnect loop and an ordered send queue added.
