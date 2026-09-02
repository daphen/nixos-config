package main

import (
	"encoding/json"
	"io"
	"strconv"
)

type niriWindow struct {
	ID             uint64        `json:"id"`
	Title          string        `json:"title"`
	AppID          string        `json:"app_id"`
	Focused        bool          `json:"is_focused"`
	FocusTimestamp niriTimestamp `json:"focus_timestamp"`
	WorkspaceID    uint64        `json:"workspace_id"`
}

type niriTimestamp struct {
	Seconds int64 `json:"secs"`
	Nanos   int64 `json:"nanos"`
}

type niriWorkspace struct {
	ID      uint64 `json:"id"`
	Index   int    `json:"idx"`
	Name    string `json:"name"`
	Focused bool   `json:"is_focused"`
}

func niriJSON(message string, dst any) error {
	data, _ := commandOutput("niri", "msg", "--json", message)
	return json.Unmarshal(data, dst)
}

func niriWindows() ([]niriWindow, error) {
	var windows []niriWindow
	err := niriJSON("windows", &windows)
	return windows, err
}

func focusedWorkspaceReference() string {
	var workspaces []niriWorkspace
	if niriJSON("workspaces", &workspaces) != nil {
		return ""
	}
	for _, workspace := range workspaces {
		if !workspace.Focused {
			continue
		}
		if workspace.Name != "" {
			return workspace.Name
		}
		if workspace.Index != 0 {
			return strconv.Itoa(workspace.Index)
		}
		break
	}
	return ""
}

func niriAction(stdout, stderr io.Writer, action string, args ...string) error {
	all := append([]string{"msg", "action", action}, args...)
	return runCommand(stdout, stderr, "niri", all...)
}
