module instance-helper

go 1.27.0

require (
	github.com/kagent-dev/kagent/go v0.0.0
	google.golang.org/grpc v1.84.0
)

require (
	buf.build/gen/go/bufbuild/protovalidate/protocolbuffers/go v1.36.12-20260825204119-511051f7f437.2 // indirect
	github.com/a2aproject/a2a-go/v2 v2.5.0 // indirect
	github.com/agent-substrate/substrate v0.5.0 // indirect
	golang.org/x/net v0.60.0 // indirect
	golang.org/x/sys v0.48.0 // indirect
	golang.org/x/text v0.42.0 // indirect
	google.golang.org/genproto/googleapis/api v0.0.0-20260825221802-da73d73af1c5 // indirect
	google.golang.org/genproto/googleapis/rpc v0.0.0-20260831171406-18b4a7587f8a // indirect
	google.golang.org/protobuf v1.36.12 // indirect
)

// The helper speaks the controller's own generated gRPC API, which lives in
// the kagent source fork this repo deploys from (see `make kagent-update`).
replace github.com/kagent-dev/kagent/go => ../../../../../kagent/go

// Mirror the fork's own pin so both sides agree on the substrate API.
replace github.com/agent-substrate/substrate => github.com/kagent-dev/substrate v0.2.0-beta5
