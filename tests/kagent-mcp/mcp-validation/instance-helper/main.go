// Command instance-helper manages a hermetic kagent AgentInstance for the
// MCP gateway e2e test. AgentInstances are controller-database objects (not
// k8s resources), so creation goes through the controller's gRPC API exactly
// like the UI does, over a temporary port-forward.
//
//	go run . create <harness> <template>   # prints {"id":...,"state":...}
//	go run . delete <instance-id>
package main

import (
	"context"
	"encoding/json"
	"fmt"
	"net"
	"os"
	"os/exec"
	"time"

	kagentpb "github.com/kagent-dev/kagent/go/api/gen/kagent/api/v1alpha1"
	"google.golang.org/grpc"
	"google.golang.org/grpc/credentials/insecure"
	"google.golang.org/grpc/metadata"
)

const (
	forwardHost = "127.0.0.1"
	forwardPort = "18084"
)

func main() {
	if len(os.Args) < 3 {
		fatal("usage: instance-helper create <harness> <template> | delete <instance-id>")
	}
	stopForward, err := startPortForward()
	if err != nil {
		fatal("port-forward: " + err.Error())
	}
	defer stopForward()

	conn, err := grpc.NewClient(net.JoinHostPort(forwardHost, forwardPort),
		grpc.WithTransportCredentials(insecure.NewCredentials()))
	if err != nil {
		fatal("dial: " + err.Error())
	}
	defer conn.Close()
	client := kagentpb.NewAgentInstanceServiceClient(conn)

	ctx, cancel := context.WithTimeout(context.Background(), 3*time.Minute)
	defer cancel()
	// The controller runs AUTH_MODE=unsecure: X-User-Id picks the principal.
	ctx = metadata.AppendToOutgoingContext(ctx, "x-user-id", "admin@kagent.dev")

	switch os.Args[1] {
	case "create":
		if len(os.Args) != 4 {
			fatal("create needs <harness> and <template>")
		}
		resp, err := client.CreateAgentInstance(ctx, &kagentpb.CreateAgentInstanceRequest{
			Harness:       &kagentpb.ResourceReference{Namespace: "kagent", Name: os.Args[2]},
			AgentTemplate: &kagentpb.ResourceReference{Namespace: "kagent", Name: os.Args[3]},
			RequestId:     fmt.Sprintf("mcp-e2e-%d", time.Now().UnixNano()),
		})
		if err != nil {
			fatal("create: " + err.Error())
		}
		emit(resp.GetAgentInstance().GetId(), resp.GetAgentInstance().GetState().String())
	case "delete":
		if len(os.Args) != 3 {
			fatal("delete needs <instance-id>")
		}
		resp, err := client.DeleteAgentInstance(ctx, &kagentpb.DeleteAgentInstanceRequest{AgentInstanceId: os.Args[2]})
		if err != nil {
			fatal("delete: " + err.Error())
		}
		emit(resp.GetAgentInstance().GetId(), resp.GetAgentInstance().GetState().String())
	default:
		fatal("unknown command " + os.Args[1])
	}
}

// startPortForward shells out to kubectl port-forward and waits until the
// local port accepts connections. If something is already listening (e.g. a
// previous helper run whose forward is still winding down), reuse it.
func startPortForward() (func(), error) {
	if conn, err := net.DialTimeout("tcp", net.JoinHostPort(forwardHost, forwardPort), time.Second); err == nil {
		_ = conn.Close()
		return func() {}, nil
	}
	cmd := exec.Command("kubectl", "port-forward", "-n", "kagent",
		"svc/kagent-controller", forwardPort+":8083")
	if err := cmd.Start(); err != nil {
		return nil, err
	}
	stop := func() {
		_ = cmd.Process.Kill()
		_ = cmd.Wait()
	}
	deadline := time.Now().Add(30 * time.Second)
	for time.Now().Before(deadline) {
		conn, err := net.DialTimeout("tcp", net.JoinHostPort(forwardHost, forwardPort), time.Second)
		if err == nil {
			_ = conn.Close()
			return stop, nil
		}
		time.Sleep(200 * time.Millisecond)
	}
	stop()
	return nil, fmt.Errorf("port-forward to %s never came up", forwardPort)
}

func emit(id, state string) {
	_ = json.NewEncoder(os.Stdout).Encode(map[string]string{"id": id, "state": state})
}

func fatal(msg string) {
	fmt.Fprintln(os.Stderr, msg)
	os.Exit(1)
}
