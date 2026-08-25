// Command server is a throwaway probe used to answer three questions about
// running NativeLink's scheduler/CAS inside a Cloud Run worker pool:
//
//  1. Is a worker pool instance reachable inbound over Direct VPC at all?
//  2. Does a long-lived HTTP/2 stream survive past the 60 minute request
//     timeout that applies to Cloud Run *services*?
//  3. Is more than one TCP port reachable, or only the declared PORT?
//
// It listens on two ports: PORT speaks h2c (HTTP/2 cleartext, the same
// transport gRPC uses) and PORT2 speaks raw TCP. Both emit a timestamped
// heartbeat every 30s so a client can measure exactly when it was cut off.
package main

import (
	"fmt"
	"log"
	"net"
	"net/http"
	"os"
	"time"

	"golang.org/x/net/http2"
	"golang.org/x/net/http2/h2c"
)

const heartbeatInterval = 30 * time.Second

// main starts both listeners and blocks forever.
func main() {
	port := envOr("PORT", "8080")
	port2 := envOr("PORT2", "8081")

	logLocalIPs()

	go serveRawTCP(port2)
	serveH2C(port)
}

// envOr returns the environment variable value or a fallback default.
func envOr(key, fallback string) string {
	if v := os.Getenv(key); v != "" {
		return v
	}
	return fallback
}

// logLocalIPs prints every non-loopback address the instance holds. This is how
// we discover the worker pool instance's private VPC IP, since Cloud Run
// exposes no API for listing worker pool instance addresses.
func logLocalIPs() {
	addrs, err := net.InterfaceAddrs()
	if err != nil {
		log.Printf("SPIKE_IP error: %v", err)
		return
	}
	for _, a := range addrs {
		if ipnet, ok := a.(*net.IPNet); ok && !ipnet.IP.IsLoopback() && ipnet.IP.To4() != nil {
			// Prefixed so it is trivially greppable in Cloud Logging.
			log.Printf("SPIKE_IP %s", ipnet.IP.String())
		}
	}
}

// serveH2C serves an HTTP/2 cleartext endpoint whose /stream handler holds the
// response open indefinitely, flushing a heartbeat every 30s. This is the
// closest cheap approximation of NativeLink's long-lived worker gRPC stream.
func serveH2C(port string) {
	mux := http.NewServeMux()
	mux.HandleFunc("/stream", streamHandler)
	mux.HandleFunc("/health", func(w http.ResponseWriter, _ *http.Request) {
		fmt.Fprintln(w, "ok")
	})

	srv := &http.Server{
		Addr:    ":" + port,
		Handler: h2c.NewHandler(mux, &http2.Server{}),
	}
	log.Printf("h2c listening on :%s", port)
	log.Fatal(srv.ListenAndServe())
}

// streamHandler writes a heartbeat every 30s until the client or the platform
// severs the connection, so the client can measure total stream lifetime.
func streamHandler(w http.ResponseWriter, r *http.Request) {
	flusher, ok := w.(http.Flusher)
	if !ok {
		http.Error(w, "streaming unsupported", http.StatusInternalServerError)
		return
	}
	w.Header().Set("Content-Type", "text/plain")
	w.WriteHeader(http.StatusOK)

	start := time.Now()
	// Flush immediately so the client confirms reachability without waiting a
	// full heartbeat interval for response headers.
	fmt.Fprintln(w, "h2c connected")
	flusher.Flush()

	ticker := time.NewTicker(heartbeatInterval)
	defer ticker.Stop()

	for {
		select {
		case <-r.Context().Done():
			log.Printf("h2c stream closed by peer after %s", time.Since(start).Round(time.Second))
			return
		case <-ticker.C:
			elapsed := time.Since(start).Round(time.Second)
			if _, err := fmt.Fprintf(w, "h2c heartbeat elapsed=%s\n", elapsed); err != nil {
				log.Printf("h2c write failed after %s: %v", elapsed, err)
				return
			}
			flusher.Flush()
		}
	}
}

// serveRawTCP accepts plain TCP connections on a second port to test whether
// Direct VPC ingress exposes ports beyond the declared PORT.
func serveRawTCP(port string) {
	ln, err := net.Listen("tcp", ":"+port)
	if err != nil {
		log.Fatalf("raw tcp listen failed: %v", err)
	}
	log.Printf("raw tcp listening on :%s", port)
	for {
		conn, err := ln.Accept()
		if err != nil {
			log.Printf("accept error: %v", err)
			continue
		}
		go handleRawConn(conn)
	}
}

// handleRawConn writes a heartbeat every 30s on a raw TCP connection.
func handleRawConn(conn net.Conn) {
	defer conn.Close()
	start := time.Now()
	for {
		time.Sleep(heartbeatInterval)
		elapsed := time.Since(start).Round(time.Second)
		if _, err := fmt.Fprintf(conn, "tcp heartbeat elapsed=%s\n", elapsed); err != nil {
			log.Printf("raw tcp write failed after %s: %v", elapsed, err)
			return
		}
	}
}
