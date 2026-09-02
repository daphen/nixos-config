package main

import "encoding/json"

type quickshellInstance struct {
	ID  string `json:"id"`
	PID int    `json:"pid"`
}

func quickshellInstances() ([]quickshellInstance, error) {
	data, err := commandOutput("qs", "list", "-a", "--json")
	if err != nil {
		return nil, err
	}
	var instances []quickshellInstance
	err = json.Unmarshal(data, &instances)
	return instances, err
}

func quickshellCall(instance, target, method string, args ...string) ([]byte, error) {
	command := []string{"ipc"}
	if instance != "" {
		command = append(command, "-i", instance)
	}
	command = append(command, "call", target, method)
	return commandOutput("qs", append(command, args...)...)
}
