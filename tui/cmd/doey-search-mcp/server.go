package main

import (
	"bufio"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"log"
	"sync"
)

// JSON-RPC 2.0 error codes.
const (
	errParse          = -32700
	errInvalidRequest = -32600
	errMethodNotFound = -32601
	errInvalidParams  = -32602
	errInternal       = -32603
)

type rpcRequest struct {
	JSONRPC string          `json:"jsonrpc"`
	ID      json.RawMessage `json:"id,omitempty"`
	Method  string          `json:"method"`
	Params  json.RawMessage `json:"params,omitempty"`
}

type rpcError struct {
	Code    int    `json:"code"`
	Message string `json:"message"`
	Data    any    `json:"data,omitempty"`
}

type rpcResponse struct {
	JSONRPC string          `json:"jsonrpc"`
	ID      json.RawMessage `json:"id,omitempty"`
	Result  any             `json:"result,omitempty"`
	Error   *rpcError       `json:"error,omitempty"`
}

// Server is a stdio JSON-RPC 2.0 MCP server. Single-threaded request loop;
// responses are serialized via a mutex to keep stdout writes well-formed.
type Server struct {
	tools   map[string]Tool
	name    string
	version string
	writeMu sync.Mutex
}

func NewServer(tools []Tool, name, version string) *Server {
	m := make(map[string]Tool, len(tools))
	for _, t := range tools {
		m[t.Name] = t
	}
	return &Server{tools: m, name: name, version: version}
}

func (s *Server) Run(ctx context.Context, r io.Reader, w io.Writer) error {
	scanner := bufio.NewScanner(r)
	scanner.Buffer(make([]byte, 0, 64*1024), 16*1024*1024)

	for scanner.Scan() {
		select {
		case <-ctx.Done():
			return ctx.Err()
		default:
		}
		line := scanner.Bytes()
		if len(line) == 0 {
			continue
		}
		var req rpcRequest
		if err := json.Unmarshal(line, &req); err != nil {
			s.writeErr(w, nil, errParse, "parse error: "+err.Error())
			continue
		}
		if req.JSONRPC != "2.0" {
			s.writeErr(w, req.ID, errInvalidRequest, "jsonrpc must be \"2.0\"")
			continue
		}
		s.dispatch(ctx, w, &req)
	}
	if err := scanner.Err(); err != nil && !errors.Is(err, io.EOF) {
		return err
	}
	return nil
}

func (s *Server) dispatch(ctx context.Context, w io.Writer, req *rpcRequest) {
	isNotification := len(req.ID) == 0

	switch req.Method {
	case "initialize":
		s.writeResult(w, req.ID, s.handleInitialize(req.Params))

	case "notifications/initialized", "initialized":
		return

	case "tools/list":
		s.writeResult(w, req.ID, s.handleToolsList())

	case "tools/call":
		result, rpcErr := s.handleToolsCall(ctx, req.Params)
		if rpcErr != nil {
			if isNotification {
				log.Printf("tools/call notification error: %s", rpcErr.Message)
				return
			}
			s.writeErrStruct(w, req.ID, rpcErr)
			return
		}
		s.writeResult(w, req.ID, result)

	case "ping":
		s.writeResult(w, req.ID, struct{}{})

	default:
		if isNotification {
			log.Printf("ignoring unknown notification: %s", req.Method)
			return
		}
		s.writeErr(w, req.ID, errMethodNotFound, "method not found: "+req.Method)
	}
}

func (s *Server) handleInitialize(_ json.RawMessage) any {
	return map[string]any{
		"protocolVersion": "2024-11-05",
		"capabilities": map[string]any{
			"tools": map[string]any{"listChanged": false},
		},
		"serverInfo": map[string]any{
			"name":    s.name,
			"version": s.version,
		},
	}
}

type toolDescriptor struct {
	Name        string          `json:"name"`
	Description string          `json:"description"`
	InputSchema json.RawMessage `json:"inputSchema"`
}

func (s *Server) handleToolsList() any {
	out := make([]toolDescriptor, 0, len(s.tools))
	for _, t := range Registry() {
		out = append(out, toolDescriptor{
			Name:        t.Name,
			Description: t.Description,
			InputSchema: t.InputSchema,
		})
	}
	return map[string]any{"tools": out}
}

type toolsCallParams struct {
	Name      string          `json:"name"`
	Arguments json.RawMessage `json:"arguments,omitempty"`
}

func (s *Server) handleToolsCall(ctx context.Context, params json.RawMessage) (any, *rpcError) {
	var p toolsCallParams
	if len(params) > 0 {
		if err := json.Unmarshal(params, &p); err != nil {
			return nil, &rpcError{Code: errInvalidParams, Message: "invalid params: " + err.Error()}
		}
	}
	if p.Name == "" {
		return nil, &rpcError{Code: errInvalidParams, Message: "tools/call: name is required"}
	}
	tool, ok := s.tools[p.Name]
	if !ok {
		return nil, &rpcError{Code: errMethodNotFound, Message: "unknown tool: " + p.Name}
	}

	result, err := tool.Handler(ctx, p.Arguments)
	if err != nil {
		return map[string]any{
			"isError": true,
			"content": []map[string]any{
				{"type": "text", "text": err.Error()},
			},
		}, nil
	}

	payload, mErr := json.Marshal(result)
	if mErr != nil {
		return nil, &rpcError{Code: errInternal, Message: "marshal tool result: " + mErr.Error()}
	}
	return map[string]any{
		"content": []map[string]any{
			{"type": "text", "text": string(payload)},
		},
	}, nil
}

func (s *Server) writeResult(w io.Writer, id json.RawMessage, result any) {
	if len(id) == 0 {
		return
	}
	s.writeJSON(w, rpcResponse{JSONRPC: "2.0", ID: id, Result: result})
}

func (s *Server) writeErr(w io.Writer, id json.RawMessage, code int, msg string) {
	s.writeErrStruct(w, id, &rpcError{Code: code, Message: msg})
}

func (s *Server) writeErrStruct(w io.Writer, id json.RawMessage, e *rpcError) {
	resp := rpcResponse{JSONRPC: "2.0", Error: e}
	if len(id) > 0 {
		resp.ID = id
	} else {
		resp.ID = json.RawMessage("null")
	}
	s.writeJSON(w, resp)
}

func (s *Server) writeJSON(w io.Writer, v any) {
	s.writeMu.Lock()
	defer s.writeMu.Unlock()

	buf, err := json.Marshal(v)
	if err != nil {
		log.Printf("marshal response: %v", err)
		return
	}
	if _, err := fmt.Fprintf(w, "%s\n", buf); err != nil {
		log.Printf("write response: %v", err)
	}
}
