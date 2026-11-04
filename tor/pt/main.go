// Pluggable transports for Pulshade's Tor: Snowflake and webtunnel from Tor Project's lyrebird, run inside the app
// rather than as a program of its own, which iOS doesn't allow. Only these two are linked: lyrebird's obfs4 and
// meek include GPL-3 code, and Pulshade is MIT. Each transport listens as a SOCKS5 proxy on
// 127.0.0.1, and Arti (tor/src/lib.rs) sends its bridge connections through them.
package main

/*
#include <stdlib.h>
*/
import "C"

import (
	"cmp"
	"io"
	"net"
	"os"
	"path/filepath"
	"strings"
	"sync"
	"unsafe"

	"gitlab.torproject.org/tpo/anti-censorship/pluggable-transports/lyrebird/common/log"
	"gitlab.torproject.org/tpo/anti-censorship/pluggable-transports/lyrebird/common/socks5"
	"gitlab.torproject.org/tpo/anti-censorship/pluggable-transports/lyrebird/transports/base"
	"gitlab.torproject.org/tpo/anti-censorship/pluggable-transports/lyrebird/transports/snowflake"
	"gitlab.torproject.org/tpo/anti-censorship/pluggable-transports/lyrebird/transports/webtunnel"
	"golang.org/x/net/proxy"
)

// The transports Pulshade offers.
var offered = []base.Transport{webtunnel.Transport, new(snowflake.Transport)}

var (
	once      sync.Once
	listening string
)

// Starts the transports once, keeping their state in stateDir, and returns where each listens:
// "webtunnel=127.0.0.1:port,snowflake=...". Empty if none could start. Free it with pulshade_pt_free.
//
//export pulshade_pt_start
func pulshade_pt_start(stateDir *C.char) *C.char {
	dir := C.GoString(stateDir)
	once.Do(func() { listening = start(dir) })
	return C.CString(listening)
}

//export pulshade_pt_free
func pulshade_pt_free(text *C.char) {
	C.free(unsafe.Pointer(text))
}

func start(dir string) string {
	// Off unless asked for, for debugging only: it names the bridges connected to.
	if os.Getenv("PULSHADE_PT_LOG") == "1" {
		_ = log.Init(true, filepath.Join(dir, "lyrebird.log"), true)
		_ = log.SetLogLevel("DEBUG")
	}
	var out []string
	for _, t := range offered {
		name := t.Name()
		f, err := t.ClientFactory(dir)
		if err != nil {
			continue
		}
		ln, err := net.Listen("tcp", "127.0.0.1:0")
		if err != nil {
			continue
		}
		go accept(f, ln)
		out = append(out, name+"="+ln.Addr().String())
	}
	return strings.Join(out, ",")
}

func accept(f base.ClientFactory, ln net.Listener) {
	for {
		conn, err := ln.Accept()
		if err != nil {
			if e, ok := err.(net.Error); ok && !e.Timeout() {
				return
			}
			continue
		}
		go handle(f, conn)
	}
}

// One connection from Arti: the SOCKS request names the bridge, and its username and password carry the bridge
// line's arguments (its certificate, URL or broker).
func handle(f base.ClientFactory, conn net.Conn) {
	defer conn.Close()
	req, err := socks5.Handshake(conn)
	if err != nil {
		return
	}
	name := f.Transport().Name()
	args, err := f.ParseArgs(&req.Args)
	if err != nil {
		log.Errorf("%s - invalid arguments: %s", name, err)
		_ = req.Reply(socks5.ReplyGeneralFailure)
		return
	}
	remote, err := f.Dial("tcp", req.Target, proxy.Direct.Dial, args)
	if err != nil {
		log.Errorf("%s(%s) - outgoing connection failed: %s", name, log.ElideAddr(req.Target), log.ElideError(err))
		_ = req.Reply(socks5.ErrorToReplyCode(err))
		return
	}
	log.Infof("%s(%s) - connected", name, log.ElideAddr(req.Target))
	defer remote.Close()
	if req.Reply(socks5.ReplySucceeded) != nil {
		return
	}
	done := make(chan error, 1)
	go func() {
		_, err := io.Copy(remote, conn)
		done <- err
	}()
	_, err = io.Copy(conn, remote)
	_ = cmp.Or(<-done, err)
}

func main() {}
