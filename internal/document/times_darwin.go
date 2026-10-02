//go:build darwin

package document

import (
	"encoding/binary"
	"os"
	"syscall"
	"time"

	"golang.org/x/sys/unix"
)

func creationTime(info os.FileInfo) *time.Time {
	stat, ok := info.Sys().(*syscall.Stat_t)
	if !ok {
		return nil
	}
	created := time.Unix(stat.Birthtimespec.Sec, stat.Birthtimespec.Nsec)
	return &created
}

func preserveCreationTime(path string, info os.FileInfo) {
	created := creationTime(info)
	if created == nil {
		return
	}
	attributes := unix.Attrlist{Bitmapcount: unix.ATTR_BIT_MAP_COUNT, Commonattr: unix.ATTR_CMN_CRTIME}
	buffer := make([]byte, 16)
	binary.NativeEndian.PutUint64(buffer, uint64(created.Unix()))
	binary.NativeEndian.PutUint64(buffer[8:], uint64(created.Nanosecond()))
	// Some external filesystems cannot preserve birth time. Saving remains
	// available there, and Information reports the timestamp the disk provides.
	_ = unix.Setattrlist(path, &attributes, buffer, 0)
}
