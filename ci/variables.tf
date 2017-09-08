variable "region" {
  type = "string"
  description = "AWS Region"
  default = "ap-south-1"
}

variable "environment" {
  type = "string"
  description = "Environment Name"
  default = "ci"
}

variable "ami" {
  type = "string"
  description = "Ubuntu 14.04 hvm:ebs-ssd AMI Mumbai"
  default = "ami-0b460164"
}


variable "instance_type" {
  type = "string"
  description = "ECS Instance Type"
  default = "t2.micro"
}

variable "disk_size" {
  description = "Size of the disks for EC2 Instances"
  default = 100
}

variable "ssh_public_key" {
  description = "Public Key used to ssh into the instances"
  default = "ssh-rsa AAAAB3NzaC1yc2EAAAADAQABAAACAQDJw2vUsJSJECTQ4n5MsVmKzowPKMTSebezmP4yopbSCc6w+MjwZLf40+SrMJxtA8zHo2kAXARc1mkMqob8C9QoA+nBU1atLmpb7GBum0QijQNY3oPXx69x2qzz6t18p6UL7jXuky0/fWTIXo+Lkh0S8wVyOWa+bS52WCNaVmhXYy6tvGk2PjQm7tFt59HXeTwFsV/U6Xm4UKTzVj5Sa+odbzXrTiw6E1rnpKGeZukSJ75vN9xPfIG8oiuP4Qe6mKZ0UXvMzSOQpz2AOqwjklXRDV0nTVE/zvZi5cfisn3q4XNUjhYxRtVBHzQI2SYNVnBCCM50trteEJVay5u/Kx45gvFmWeznqi3M5FuPdLpk6ZAI90HmAGatFYoucPqv+8hwyeOgq6Eglw10ZK11ECUX6+nRF9FBCa/rsNaUPfhiGVEaac21uz4sCmvrhPtw48cPYG352MM0VqafSeD6Uht1kDtn/Il+6hiAN3RGRNBVCDwUcqvA9vbMggnCgmQwvCdYa7tlYw9PjIRHdkmPJdMma1bdrvogucLCF2UNcmSnwLemOZ2sBHDHNOQR3uy/1rJSaqt2Wxwhg6XErckOfNySLOMmkBjqjvqs2/Cq+mVhYIxk3EetWz4AxcrX415/EpEg2Ut6J02+OzbAJZ6+8H9VQEdsUycZZs00Nck5eAyesQ== openchs"
}

variable "key_name" {
  description = "Key Name"
  default = "openchs"
}
