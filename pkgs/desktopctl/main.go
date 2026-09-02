package main

import (
	"fmt"
	"os"
)

type commandStatus struct {
	code int
	err  error
}

func (e commandStatus) Error() string { return e.err.Error() }

func main() {
	if len(os.Args) < 2 {
		fmt.Fprintln(os.Stderr, "usage: desktopctl <command> [arguments...]")
		os.Exit(1)
	}

	var err error
	switch os.Args[1] {
	case "browser-dispatch":
		err = runBrowser(os.Args[2:])
	case "launch-mail-client":
		if len(os.Args) != 2 {
			fmt.Fprintln(os.Stderr, "usage: desktopctl launch-mail-client")
			os.Exit(1)
		}
		err = runMail()
	case "niri-jump-or-exec":
		err = jumpOrExec(os.Args[2:])
	case "notification-dispatch":
		err = runNotification(os.Args[2:])
	default:
		fmt.Fprintf(os.Stderr, "desktopctl: unknown command %q\n", os.Args[1])
		os.Exit(1)
	}
	if err != nil {
		if status, ok := err.(commandStatus); ok {
			fmt.Fprintln(os.Stderr, status.err)
			os.Exit(status.code)
		}
		os.Exit(1)
	}
}
