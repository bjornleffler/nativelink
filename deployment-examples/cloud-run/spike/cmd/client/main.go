// Command client runs inside the VPC (on a GCE VM) and probes the spike server
// running in a Cloud Run worker pool. It answers whether the instance is
// reachable, whether a second port is reachable, and how long a long-lived
// stream actually survives.
//
// Usage:
//
//	go run -tags client client.go -host 10.0.0.5 -duration 75m
package main
import (
	"bufio"
	"context"
	"crypto/tls"
	"flag"
	"fmt"
	"log"
	"net"
	"net/http"
	"sync"
	"time"
	"golang.org/x/net/http2"
)
// sixtyMinutes is the Cloud Run *services* request timeout ceiling. The whole
// point of the spike is to find out whether it also applies here.
const sixtyMinutes = 60 * time.Minute
// main probes both ports concurrently and prints a verdict for each.
func main() {
	host := flag.String("host", "", "worker pool instance private IP (required)")
	h2cPort := flag.String("h2c-port", "8080", "h2c port (the declared PORT)")
	tcpPort := flag.String("tcp-port", "8081", "raw TCP port (the second port)")
	duration := flag.Duration("duration", 75*time.Minute, "how long to hold the streams")
	flag.Parse()
	if *host == "" {
		log.Fatal("-host is required (find it by grepping Cloud Logging for SPIKE_IP)")
	}
	ctx, cancel := context.WithTimeout(context.Background(), *duration)
	defer cancel()
	var wg sync.WaitGroup
	wg.Add(2)
	go func() { defer wg.Done(); probeH2C(ctx, *host, *h2cPort) }()
	go func() { defer wg.Done(); probeRawTCP(ctx, *host, *tcpPort) }()
	wg.Wait()
	log.Printf("=== spike complete after %s ===", *duration)
}
// probeH2C holds an HTTP/2 stream open and reports how long it lasted.
func probeH2C(ctx context.Context, host, port string) {
	addr := net.JoinHostPort(host, port)
	// h2c: force HTTP/2 over a plaintext connection, no TLS.
	client := &http.Client{
		Transport: &http2.Transport{
			AllowHTTP: true,
			DialTLSContext: func(ctx context.Context, network, addr string, _ *tls.Config) (net.Conn, error) {
				var d net.Dialer
				return d.DialContext(ctx, network, addr)
			},
		},
	}
	start := time.Now()
	req, err := http.NewRequestWithContext(ctx, "GET", "http://"+addr+"/stream", nil)
	if err != nil {
		log.Fatalf("h2c: building request: %v", err)
	}
	resp, err := client.Do(req)
	if err != nil {
		log.Printf("H2C VERDICT: UNREACHABLE after %s: %v", time.Since(start).Round(time.Second), err)
		return
	}
	defer resp.Body.Close()
	log.Printf("h2c: connected to %s, holding stream...", addr)
	readUntilClosed(resp.Body, "h2c", start)
	reportVerdict("H2C", time.Since(start))
}
// probeRawTCP holds a plain TCP connection open and reports how long it lasted.
func probeRawTCP(ctx context.Context, host, port string) {
	addr := net.JoinHostPort(host, port)
	start := time.Now()
	var d net.Dialer
	conn, err := d.DialContext(ctx, "tcp", addr)
	if err != nil {
		log.Printf("TCP VERDICT: UNREACHABLE after %s: %v", time.Since(start).Round(time.Second), err)
		log.Printf("  -> only the declared PORT is exposed; the merged-port config is required")
		return
	}
	defer conn.Close()
	log.Printf("tcp: connected to %s, holding connection...", addr)
	go func() { <-ctx.Done(); conn.Close() }()
	readUntilClosed(conn, "tcp", start)
	reportVerdict("TCP", time.Since(start))
}
// readUntilClosed drains heartbeats, logging every 10th so output stays sane.
func readUntilClosed(r interface{ Read([]byte) (int, error) }, label string, start time.Time) {
	scanner := bufio.NewScanner(r)
	count := 0
	for scanner.Scan() {
		count++
		if count%10 == 0 {
			log.Printf("%s: %d heartbeats, elapsed %s", label, count, time.Since(start).Round(time.Second))
		}
	}
	if err := scanner.Err(); err != nil {
		log.Printf("%s: stream ended with error after %s: %v", label, time.Since(start).Round(time.Second), err)
	}
}
// reportVerdict prints whether the stream outlived the 60 minute service cap.
func reportVerdict(label string, elapsed time.Duration) {
	rounded := elapsed.Round(time.Second)
	switch {
	case elapsed >= sixtyMinutes:
		fmt.Printf("\n%s VERDICT: PASS - stream survived %s, past the 60m service cap\n", label, rounded)
	case elapsed > 55*time.Minute:
		fmt.Printf("\n%s VERDICT: FAIL - stream cut at %s, right at the 60m cap\n", label, rounded)
	default:
		fmt.Printf("\n%s VERDICT: INCONCLUSIVE - stream ended early at %s (check server logs)\n", label, rounded)
	}
}
