# ivLyrics for YouTube Music (iOS)
#
#   make package                      -> ivLyricsYTM.dylib (sideload / IPA injection, default)
#   make package JAILBREAK=1          -> .deb tweak for jailbroken devices
#   make package JAILBREAK=1 ROOTLESS=1
#
#   Discord Rich Presence (optional): point DISCORD_SDK at the directory that contains
#   discord_partner_sdk.framework (the iOS device slice of the official Social SDK).
#   The SDK is loaded at run time from discord_partner_sdk.dylib next to the tweak:
#   make package DISCORD_SDK=/path/to/discord_partner_sdk.xcframework/ios-arm64

TARGET := iphone:clang:latest:18.0
ARCHS := arm64
INSTALL_TARGET_PROCESSES = YouTubeMusic
PACKAGE_VERSION = 1.0.0
GIT_COMMIT := $(shell git rev-parse --short=7 HEAD 2>/dev/null || echo dev)

ifeq ($(ROOTLESS),1)
THEOS_PACKAGE_SCHEME = rootless
else ifeq ($(ROOTHIDE),1)
THEOS_PACKAGE_SCHEME = roothide
endif

include $(THEOS)/makefiles/common.mk

ifeq ($(JAILBREAK),1)
TWEAK_NAME = ivLyricsYTM
else
LIBRARY_NAME = ivLyricsYTM
endif

ivLyricsYTM_FILES = $(wildcard Sources/*.x) $(wildcard Sources/*.m) $(wildcard Sources/*.mm)
ivLyricsYTM_CFLAGS = -fobjc-arc -Wno-deprecated-declarations -Wno-unused-function -Wno-format-nonliteral -Wno-format-security -Wno-error -ISources -DIVL_VERSION=\"$(PACKAGE_VERSION)\" -DIVL_COMMIT=\"$(GIT_COMMIT)\"
ivLyricsYTM_CCFLAGS = -std=c++20 -fno-modules -fno-cxx-modules
ivLyricsYTM_FRAMEWORKS = UIKit Foundation QuartzCore CoreText CoreImage NaturalLanguage MediaPlayer WebKit Security Network AVFoundation AVKit ShazamKit UniformTypeIdentifiers

ifneq ($(DISCORD_SDK),)
# The SDK is not linked: tools/gen_discord_stubs.py turns its C API into forwarding stubs that are
# bound with dlopen/dlsym at run time (see IVLDiscord.mm). Only the headers are needed to build.
_IVL_DISCORD_STUBS := $(shell python3 tools/gen_discord_stubs.py "$(DISCORD_SDK)/discord_partner_sdk.framework/Headers/cdiscord.h" Sources/IVLDiscordStubs.c 1>&2 && echo Sources/IVLDiscordStubs.c)
ivLyricsYTM_FILES += $(_IVL_DISCORD_STUBS)
ivLyricsYTM_CFLAGS += -DIVL_DISCORD=1 -F$(DISCORD_SDK)
endif
# Hooks use the ObjC runtime directly -> the dylib has no CydiaSubstrate/ElleKit dependency
ivLyricsYTM_LOGOS_DEFAULT_GENERATOR = internal

ifeq ($(JAILBREAK),1)
include $(THEOS_MAKE_PATH)/tweak.mk
else
ivLyricsYTM_INSTALL_PATH = /Library/ivLyrics
include $(THEOS_MAKE_PATH)/library.mk
endif
