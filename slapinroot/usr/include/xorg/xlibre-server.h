/* xorg-server.h.in						-*- c -*-
 *
 * This file is the template file for the xorg-server.h file which gets
 * installed as part of the SDK.  The #defines in this file overlap
 * with those from config.h, but only for those options that we want
 * to export to external modules.  Boilerplate autotool #defines such
 * as HAVE_STUFF and PACKAGE_NAME is kept in config.h
 *
 * It is still possible to update config.h.in using autoheader, since
 * autoheader only creates a .h.in file for the first
 * AM_CONFIG_HEADER() line, and thus does not overwrite this file.
 *
 * However, it should be kept in sync with this file.
 */

#ifndef _XORG_SERVER_H_
#define _XORG_SERVER_H_

#ifdef HAVE_XORG_CONFIG_H
#error Include xorg-config.h when building the X server
#endif

/* Default font path */
#define COMPILEDDEFAULTFONTPATH "/usr/share/fonts/X11/misc,/usr/share/fonts/X11/TTF,/usr/share/fonts/X11/OTF,/usr/share/fonts/X11/Type1,/usr/share/fonts/X11/100dpi,/usr/share/fonts/X11/75dpi"

/* Support Composite Extension */
#define COMPOSITE 1

/* Build DPMS extension */
#define DPMSExtension 1

/* Build DRI3 extension */
#define DRI3 1

/* Build GLX extension */
#define GLXEXT 1

/* Support XDM-AUTH*-1 */
#define HASXDMAUTH 1

/* Add a padding for legacy nvidia drivers that support old ABI */
#undef CONFIG_LEGACY_NVIDIA_PADDING

/* Define to 1 if you have the `reallocarray' function. */
#define HAVE_REALLOCARRAY 1

/* Define to 1 if you have the `strlcat' function. */
#define HAVE_STRLCAT 1

/* Define to 1 if you have the `strlcpy' function. */
#define HAVE_STRLCPY 1

/* Define to 1 if you have the `strndup' function. */
#define HAVE_STRNDUP 1

/* Support IPv6 for TCP connections */
#define IPv6 1

/* Support MIT-SHM Extension */
#define MITSHM 1
#define CONFIG_MITSHM 1

/* Internal define for Xinerama */
#define PANORAMIX 1
#define XINERAMA 1

/* Support Present extension */
#define PRESENT 1

/* Support RANDR extension */
#define RANDR 1

/* Support RENDER extension */
#define RENDER 1

/* Support X resource extension */
#define RES 1

/* Support MIT-SCREEN-SAVER extension */
#define SCREENSAVER 1

/* Support SHAPE extension */
#define SHAPE 1

/* Define to 1 on systems derived from System V Release 4 */
#undef SVR4

/* Support UNIX socket connections */
#define UNIXCONN 1

/* Support XCMisc extension */
#define XCMISC 1

/* Support Xdmcp */
#define XDMCP 1

/* Support XFree86 Video Mode extension */
#define XF86VIDMODE 1

/* Build XDGA support */
#define XFreeXDGA 1

/* Support Xinerama extension */
#define XINERAMA 1

/* Support X Input extension */
#define XINPUT 1

/* XKB default rules */
#define XKB_DFLT_RULES "evdev"

/* Build DRI extension */
#define XF86DRI 1

/* Build DRI2 extension */
#define DRI2 1

/* Build Xorg server */
#define XORGSERVER 1

/* Current Xorg version */
#define XORG_VERSION_CURRENT 12502000

/* Build Xv Extension */
#define XvExtension 1

/* Build XvMC Extension */
#define XvMCExtension 1

/* Support XSync extension */
#define XSYNC 1

/* Support XTest extension */
#define XTEST 1

/* Support Xv Extension */
#define XV 1

/* BSD-compliant source */
/* #undef _BSD_SOURCE */

/* POSIX-compliant source */
/* #undef _POSIX_SOURCE */

/* X/Open-compliant source */
/* #undef _XOPEN_SOURCE */

/* Location of configuration file */
#define XCONFIGFILE "xorg.conf"

/* Name of X server */
#define __XSERVERNAME__ "Xorg"

/* Building vgahw module */
#define WITH_VGAHW 1

/* System is BSD-like */
#undef CSRG_BASED

/* System has PCVT console */
#undef PCVT_SUPPORT

/* System has syscons console */
#undef SYSCONS_SUPPORT

/* System has wscons console */
#undef WSCONS_SUPPORT

/* BSD console support (xf86Info.consType machinery + console_*.c backends) */
#undef CONFIG_BSD_CONSOLE

/* Loadable XFree86 server awesomeness */
#define XFree86LOADER

/* Use libpciaccess */
#define XSERVER_LIBPCIACCESS 1

/* Have the pci_device_is_boot_display function */
#define HAVE_PCI_DEVICE_IS_BOOT_DISPLAY 1

/* X Access Control Extension */
#define XACE 1

/* Have X server platform bus support */
#define XSERVER_PLATFORM_BUS 1

#ifdef _LP64
#define _XSERVER64 1
#endif

/* Have support for X shared memory fence library (xshmfence) */
#define HAVE_XSHMFENCE 1

/* Use XTrans FD passing support */
#define XTRANS_SEND_FDS 1

/* Ask fontsproto to make font path element names const */
#define FONT_PATH_ELEMENT_NAME_CONST    1

/* byte order */
#define X_BYTE_ORDER X_LITTLE_ENDIAN

/* maximum number of clients */
#define MAXCLIENTS 2048

/* announce server API features */
#define XORG_API_DIX_SCREEN_HOOK_WINDOW_DESTROY 1
#define XORG_API_DIX_SCREEN_HOOK_WINDOW_POSITION 1
#define XORG_API_DIX_SCREEN_HOOK_CLOSE 1
#define XORG_API_DIX_SCREEN_HOOK_PIXMAP_DESTROY 1

/* needed for os.h to prevent redefinition of timingsafe_memcmp in drivers */
#undef HAVE_TIMINGSAFE_MEMCMP

/* Xserver has xf86ParseEDID() et al (since 25.2) */
#define XLIBRE_API_EDID_PARSE_v1 1

#endif /* _XORG_SERVER_H_ */
