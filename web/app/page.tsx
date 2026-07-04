import { redirect } from "next/navigation";

// web/ is the Gateway (API) + auth surface only. Product marketing and pricing
// live in web-product (universal-io.com). Anyone hitting the root is sent to
// sign-in, which is what this host is for.
export default function Home() {
  redirect("/auth");
}
