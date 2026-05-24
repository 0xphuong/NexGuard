import Content from "./readme.mdx";
import { Metadata } from "next";

export const metadata: Metadata = {
  title: "Administer • Firezone Docs",
  description: "NexGuard Documentation",
};

export default function Page() {
  return <Content />;
}
