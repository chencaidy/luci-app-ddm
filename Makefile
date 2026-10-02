#
# Copyright (C) 2025 luci-app-ddm contributors
#
# This is free software, licensed under the Apache License, Version 2.0.
#

include $(TOPDIR)/rules.mk

PKG_LICENSE:=Apache-2.0
PKG_MAINTAINER:=OpenWrt DDM Package Maintainers

LUCI_TITLE:=LuCI support for SFP DDM diagnostics
LUCI_DESCRIPTION:=Web UI for monitoring SFP/SFP+/SFP28 transceivers and \
	displaying SFF-8472 digital diagnostic monitoring (DDM) data, such as \
	module temperature, supply voltage, laser bias current and TX/RX \
	optical power, together with the alarm/warning thresholds stored in \
	the transceiver EEPROM.
LUCI_DEPENDS:=+luci-base +ucode +ucode-mod-fs +rpcd +rpcd-mod-ucode +ethtool
LUCI_PKGARCH:=all

include $(TOPDIR)/feeds/luci/luci.mk

# call BuildPackage - OpenWrt buildroot signature
