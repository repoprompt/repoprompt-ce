import React from "react";

export interface ButtonProps {
  label: string;
  onClick?(): void;
}

export type ButtonState = "idle" | "busy";

export function Button(props: ButtonProps) {
  return <button onClick={props.onClick}>{props.label}</button>;
}

export const Toolbar = ({ children }: { children: React.ReactNode }) => {
  return <div className="toolbar">{children}</div>;
};
